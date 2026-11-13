import AppKit
import CryptoKit
import Foundation
import Observation

/// App 内一键更新：自己下载新版 DMG → 用 GitHub 公布的 SHA-256 校验 → 解出新的 TuneFree.app 并检查
/// → 替换当前 App → 重新打开。
///
/// 为什么不用浏览器下载：浏览器下的文件带「来自网络」隔离标记，没公证的 App 每个新版本都会被
/// Gatekeeper 拦一次、要去系统设置里允许。App 自己下载的文件没有这个标记。
/// 也正因为绕开了这一层检查，这里的校验必须做足：校验值对不上、签名不对、包名不对、版本不新，一律不装。
@Observable
final class UpdateInstaller {
    enum State: Equatable {
        case idle
        case downloading(Double)      // 0…1
        case verifying
        case installing
        case relaunching
        case failed(String)
    }

    var state: State = .idle
    var isBusy: Bool {
        switch state {
        case .downloading, .verifying, .installing, .relaunching: return true
        default: return false
        }
    }

    static let bundleID = "io.github.zksbx.tunefree"

    /// 更新用到的所有临时文件都在这里（每次一个子目录），结束后整个删掉
    static let updateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/TuneFree/update", isDirectory: true)
    /// 新版没能正常启动、已经恢复旧版时留下的标记（旧版启动时读到就提示用户，然后删掉）
    static let rolledBackMarker = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/TuneFree/update-rolled-back")
    /// 新版启动后要在这么多秒内报到，否则视为更新失败、恢复旧版
    static let healthTimeout = 25

    private var work: URL?
    private var release: ReleaseInfo?

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    /// 现在的 App 能不能原地替换（不能就只能走手动下载）
    static func canSelfUpdate() -> (ok: Bool, reason: String) {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", Bundle.main.bundleIdentifier == bundleID else {
            return (false, "开发版不能自动更新")
        }
        if bundle.path.contains("/AppTranslocation/") {
            return (false, "TuneFree 还没放进「应用程序」文件夹（现在是从下载的位置直接打开的），请先把它拖进「应用程序」")
        }
        let parent = bundle.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) {
            return (false, "没有权限写入「\(parent)」")
        }
        return (true, "")
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let work { Self.removeWork(work) }
        work = nil
        state = .idle
    }

    func install(_ release: ReleaseInfo) {
        guard !isBusy else { return }
        self.release = release
        let check = Self.canSelfUpdate()
        guard check.ok else { fail(check.reason); return }
        var source = release.downloadURL
        var digest = release.sha256
        if let local = ProcessInfo.processInfo.environment["TUNEFREE_DEBUG_UPDATE_DMG"] {
            // 调试：用本地打好的 DMG 当作「新版本」，校验值现场算（测完整的更新 / 回滚流程）
            source = URL(fileURLWithPath: local)
            digest = Self.sha256(of: URL(fileURLWithPath: local))
        }
        if ProcessInfo.processInfo.environment["TUNEFREE_DEBUG_BAD_DIGEST"] == "1" {
            digest = String(repeating: "0", count: 64)      // 调试：测「校验失败 → 降级手动更新」
        }
        guard let url = source, let expected = digest, expected.count == 64 else {
            fail("拿不到这个版本的校验值，为了安全不自动安装")
            return
        }
        state = .downloading(0)
        let work = Self.updateRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        self.work = work

        let task = Updater.session.downloadTask(with: url) { [weak self] tmp, response, error in
            guard let self else { return }
            // 下载完的临时文件在回调返回后就会被删，先挪走
            var dmg: URL?
            let ok = url.isFileURL || (response as? HTTPURLResponse)?.statusCode == 200
            if let tmp, error == nil, ok {
                let dest = work.appendingPathComponent(url.lastPathComponent)
                if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil { dmg = dest }
            }
            DispatchQueue.main.async {
                self.observation = nil
                self.task = nil
                if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
                guard let dmg else {
                    self.fail("下载失败：\(error?.localizedDescription ?? "服务器没有返回文件")")
                    Self.removeWork(work)
                    self.work = nil
                    return
                }
                self.state = .verifying
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Self.verifyAndStage(dmg: dmg, expectedSHA256: expected, work: work, release: release)
                    DispatchQueue.main.async {
                        switch result {
                        case .failure(let message):
                            self.fail(message)
                            Self.removeWork(work)
                            self.work = nil
                        case .success(let staged):
                            self.state = .installing
                            self.replaceAndRelaunch(with: staged, work: work, version: release.version)
                        }
                    }
                }
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.state { self?.state = .downloading(progress.fractionCompleted) }
            }
        }
        self.task = task
        task.resume()
    }

    /// 自动更新失败：说明原因，并自动降级为原来的手动更新（浏览器下载对应芯片的 DMG）
    private func fail(_ reason: String) {
        let text = reason.hasSuffix("。") ? String(reason.dropLast()) : reason
        if let release, let url = release.downloadURL ?? Updater.manualDownloadURL(version: release.version) {
            Self.openManualDownload(url)
            state = .failed("\(text)。已改为手动更新：浏览器正在下载新版本，下载好后打开它，把 TuneFree 拖进「应用程序」替换旧版即可。")
        } else {
            state = .failed("\(text)。请到发布页手动下载新版本。")
        }
    }

    /// 用浏览器下载（老的手动更新方式）。调试时用 TUNEFREE_DEBUG_FALLBACK_LOG 记下网址，不真的打开浏览器。
    static func openManualDownload(_ url: URL) {
        if let log = ProcessInfo.processInfo.environment["TUNEFREE_DEBUG_FALLBACK_LOG"] {
            try? (url.absoluteString + "\n").write(toFile: log, atomically: true, encoding: .utf8)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private enum StageResult { case success(URL), failure(String) }

    /// 校验 DMG → 挂载 → 拷出 TuneFree.app → 检查签名 / 包名 / 版本 / 架构
    private static func verifyAndStage(dmg: URL, expectedSHA256: String, work: URL, release: ReleaseInfo) -> StageResult {
        guard let actual = sha256(of: dmg) else { return .failure("读不了下载的文件") }
        guard actual == expectedSHA256 else {
            return .failure("下载的文件和 GitHub 公布的校验值对不上（可能下载不完整或被篡改），已停止安装")
        }
        let mount = work.appendingPathComponent("mnt")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet",
                                        "-mountpoint", mount.path, dmg.path]) == 0 else {
            return .failure("打不开下载的安装包")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

        guard let source = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            return .failure("安装包里没有找到 TuneFree")
        }
        let staged = work.appendingPathComponent("TuneFree.app")
        guard run("/usr/bin/ditto", [source.path, staged.path]) == 0 else { return .failure("解出新版本失败") }
        // 清掉所有扩展属性：隔离标记，以及 DMG 制作工具留下的 FinderInfo（严格签名校验不允许它们）
        _ = run("/usr/bin/xattr", ["-cr", staged.path])

        guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else {
            return .failure("安装包里的 App 不是 TuneFree")
        }
        let version = info["CFBundleVersion"] as? String ?? ""
        guard version == release.version || Updater.isNewer(version, than: Updater.currentVersion) else {
            return .failure("安装包里的版本（\(version)）和预期不符")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]) == 0 else {
            return .failure("新版本的签名校验没有通过，已停止安装")
        }
        let exe = staged.appendingPathComponent("Contents/MacOS/TuneFree")
        let archs = runOutput("/usr/bin/lipo", ["-archs", exe.path]) ?? ""
        guard archs.split(separator: " ").contains(where: { $0 == Updater.archSuffix }) else {
            return .failure("下载的安装包不适合这台 Mac 的芯片")
        }
        try? FileManager.default.removeItem(at: dmg)      // DMG 用完就删，不占地方
        if ProcessInfo.processInfo.environment["TUNEFREE_DEBUG_BREAK_UPDATE"] == "1" {
            // 调试：故意把装上去的新版弄坏（校验之后），用来测「新版起不来 → 自动恢复旧版」
            try? Data("broken".utf8).write(to: exe)
        }
        return .success(staged)
    }

    /// 原地替换当前 App（旧版先挪去备份，不删），然后交给一个小脚本：
    /// 等当前进程退出 → 打开新版 → 等新版报到；报到了就删掉备份和所有临时文件，
    /// 超时没报到（崩溃 / 打不开 / 被拦）就杀掉新版、把旧版放回原处并重新打开。
    private func replaceAndRelaunch(with staged: URL, work: URL, version: String) {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        let backup = work.appendingPathComponent("TuneFree.previous.app")
        do {
            try fm.moveItem(at: target, to: backup)
        } catch {
            fail("挪开旧版本失败：\(error.localizedDescription)")
            Self.removeWork(work); self.work = nil
            return
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            // 新版放不进去：立刻把旧版放回来
            try? fm.moveItem(at: backup, to: target)
            fail("安装新版本失败，已保留当前版本：\(error.localizedDescription)")
            Self.removeWork(work); self.work = nil
            return
        }
        // 新版启动后看到 pending 就写 healthy 报到
        try? version.write(to: work.appendingPathComponent("pending"), atomically: true, encoding: .utf8)
        state = .relaunching

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        pid="$1"; target="$2"; backup="$3"; work="$4"; marker="$5"; version="$6"; timeout="$7"
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/open "$target"
        n=0
        while [ $n -lt $((timeout * 5)) ]; do
          [ -f "$work/healthy" ] && break
          /bin/sleep 0.2; n=$((n + 1))
        done
        cleanup() {
          /usr/bin/hdiutil detach -quiet -force "$work/mnt" 2>/dev/null
          /bin/rm -rf "$work"
          /bin/rmdir "$(/usr/bin/dirname "$work")" 2>/dev/null
        }
        if [ -f "$work/healthy" ]; then
          cleanup
          exit 0
        fi
        # 新版没有报到：恢复旧版
        /usr/bin/pkill -f "$target/Contents/MacOS/" 2>/dev/null
        /bin/sleep 0.5
        if [ -d "$backup" ]; then
          /bin/rm -rf "$target" && /bin/mv "$backup" "$target" && printf '%s' "$version" > "$marker"
          /usr/bin/open "$target"
        fi
        cleanup
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "tunefree-update", String(pid), target.path, backup.path, work.path,
                            Self.rolledBackMarker.path, version, String(Self.healthTimeout)]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        // 干净的环境：`open` 会把调用者的环境变量传给新打开的 App，不能把调试开关之类的带过去
        helper.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("TUNEFREE_DEBUG_") || $0.key == "TUNEFREE_DEBUG_FALLBACK_LOG"
        }
        try? helper.run()
        self.work = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // 有 sheet 开着时 AppKit 不肯退出：先把所有 sheet 关掉
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            NSApp.terminate(nil)
            // 兜底：2 秒后还没退出就直接退（更新只在没有转换任务时进行，这里没有要保存的东西）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }

    // MARK: - 启动时：报到、回滚提示、清理残留

    /// 每次启动调用：
    /// 1. 如果自己是刚装上的新版（有 pending 且版本对得上），写 healthy 报到，让更新脚本收尾；
    /// 2. 如果上次更新失败被恢复了，返回那个版本号（界面提示一次），并删掉标记；
    /// 3. 清掉 15 分钟前留下的更新目录（崩溃、断电等中断的更新），先卸载里面没卸掉的 DMG。
    static func onLaunch() -> String? {
        let fm = FileManager.default
        let current = Updater.currentVersion
        let dirs = (try? fm.contentsOfDirectory(at: updateRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for dir in dirs {
            let pending = dir.appendingPathComponent("pending")
            if let expected = try? String(contentsOf: pending, encoding: .utf8), expected == current {
                fm.createFile(atPath: dir.appendingPathComponent("healthy").path, contents: Data())
                continue
            }
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) > 15 * 60 {
                removeWork(dir)
            }
        }
        if (try? fm.contentsOfDirectory(atPath: updateRoot.path))?.isEmpty == true {
            try? fm.removeItem(at: updateRoot)
        }
        // 旧版本用系统默认网络缓存留下的 Cache.db / fsCachedData（现在改成不缓存了），清掉
        let caches = updateRoot.deletingLastPathComponent()
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
            try? fm.removeItem(at: caches.appendingPathComponent(name))
        }
        guard let failed = try? String(contentsOf: rolledBackMarker, encoding: .utf8) else { return nil }
        try? fm.removeItem(at: rolledBackMarker)
        return failed.isEmpty ? "新版本" : failed
    }

    /// 删一个更新目录：先卸载里面可能还挂着的 DMG
    static func removeWork(_ dir: URL) {
        let mount = dir.appendingPathComponent("mnt")
        if FileManager.default.fileExists(atPath: mount.path) {
            run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
        }
        try? FileManager.default.removeItem(at: dir)
        if (try? FileManager.default.contentsOfDirectory(atPath: updateRoot.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: updateRoot)
        }
    }

    // MARK: - 小工具

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func runOutput(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
