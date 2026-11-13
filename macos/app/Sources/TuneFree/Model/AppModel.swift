import AppKit
import Foundation
import Observation
import Security
import SwiftUI

enum OutputMode: String, CaseIterable, Identifiable {
    case mp3, both, lossless
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mp3: return "仅 MP3"
        case .both: return "MP3 + 无损"
        case .lossless: return "仅无损"
        }
    }
    var subtitle: String {
        switch self {
        case .mp3: return "体积小，随处可播"
        case .both: return "两份都留，一步到位"
        case .lossless: return "FLAC 原样保留"
        }
    }
    var symbol: String {
        switch self {
        case .mp3: return "music.note"
        case .both: return "square.stack.3d.up.fill"
        case .lossless: return "waveform"
        }
    }
}

enum Phase: Equatable {
    case idle        // 还没选目录
    case scanning    // 正在列文件 / 探查
    case ready       // 列表就绪
    case running
    case finished
}

/// 外观：跟随系统 / 浅色 / 深色
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    /// 窗口标题栏、弹窗、设置窗口这些 AppKit 部分也要跟着变
    func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum SheetKind: String, Identifiable {
    case onboarding   // 首次打开：使用说明 + 免责声明（必须同意）
    case about        // 从菜单再次查看说明
    case update       // 检查更新结果
    case settings     // 设置（版本、仓库、检查更新、外观等）
    var id: String { rawValue }
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let level: String
    let message: String
}

struct RunSummary {
    var found = 0
    var decrypted = 0
    var decryptFailed = 0
    var decryptSkipped = 0
    var mp3OK = 0
    var mp3Failed = 0
    var mp3Skipped = 0
    var cancelled = false
    var elapsed: Double = 0
    var errors: [(path: String, stage: String, reason: String, message: String)] = []

    var failed: Int { decryptFailed + mp3Failed }
    var succeeded: Int { decrypted + decryptSkipped }
}

@Observable
final class AppModel {
    // 目录
    var inputURL: URL?
    var outputURL: URL

    // 列表
    var tracks: [Track] = []
    var phase: Phase = .idle

    // 选项（持久化）
    var outputMode: OutputMode { didSet { save() } }
    var bitrate: Int { didSet { save() } }
    /// 并行转码数。只在用户自己改过时才记下来，没改过就一直跟着「CPU 核心数的一半」走
    var jobs: Int { didSet { defaults.set(jobs, forKey: "parallelJobs") } }

    /// 默认并行数：CPU 核心数的一半（至少 1）
    static var defaultJobs: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / 2) }
    /// 并行数上限：核心数，至少 8
    static var maxJobs: Int { max(8, ProcessInfo.processInfo.activeProcessorCount) }
    var verify: Bool { didSet { save() } }
    var fillTags: Bool { didSet { save() } }
    var force: Bool { didSet { save() } }
    var onlineTags: Bool { didSet { save() } }
    /// 转换完成时播放提示音、在程序坞跳一下
    var finishSound: Bool { didSet { defaults.set(finishSound, forKey: "finishSound") } }
    var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearanceMode")
            appearance.apply()
        }
    }
    var writeLrc: Bool { didSet { save() } }

    // 运行状态
    var stage: String = ""          // 解密 / 转码
    var stageDone = 0
    var stageTotal = 0
    var currentFile = ""
    var startedAt: Date?
    var summary: RunSummary?
    var logs: [LogLine] = []
    var showLog = false
    var cancelling = false
    var lastError: String?

    // 弹窗
    var sheet: SheetKind?
    /// 别的弹窗开着时发现了新版本：等它关掉再弹
    private var pendingUpdateSheet = false

    var needsOnboarding: Bool {
        UserDefaults.standard.integer(forKey: "disclaimerAcceptedVersion") < OnboardingView.disclaimerVersion
    }

    func dismissSheet() {
        sheet = nil
        if pendingUpdateSheet {
            pendingUpdateSheet = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.sheet == nil, self.phase != .running else { return }
                self.sheet = .update
            }
        }
    }

    /// 自动检查发现新版本：转换中不打扰（顶栏有提示），有弹窗开着就排队
    func presentUpdateIfQuiet() {
        guard phase != .running else { return }
        if sheet == nil { sheet = .update } else if sheet != .update { pendingUpdateSheet = true }
    }

    // 环境
    let hasFFmpeg: Bool
    let hasQQLogin: Bool
    let bundled: Bool

    private var process: BackendProcess?
    /// 载入文件夹时的探查 + 查封面（查封面可能要十几秒，和转换互不影响）
    private var previewProcess: BackendProcess?
    private let defaults = UserDefaults.standard

    static let qqCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iQmc")

    // MARK: - 完全磁盘访问权限
    //
    // App Store 版 QQ音乐是沙盒 App，歌曲和登录信息都在它的容器里。macOS 对「读别的 App 的数据」
    // 弹的授权只在发起读取的那个进程活着时有效，而真正读文件的是一闪而过的后端子进程，
    // 弹窗会跟着子进程一起消失，用户来不及点。完全磁盘访问权限是长期的，也覆盖子进程。

    /// 需要提示用户去开完全磁盘访问权限（QQ音乐是沙盒版，且 TuneFree 还没有这个权限）
    var needsFullDiskAccess = false
    var fullDiskAccessBannerDismissed: Bool {
        didSet { UserDefaults.standard.set(fullDiskAccessBannerDismissed, forKey: "fdaBannerDismissed") }
    }
    private var activationObserver: NSObjectProtocol?

    func refreshDiskAccess() {
        DispatchQueue.global(qos: .utility).async {
            let need = AppModel.qqMusicIsSandboxed() && !AppModel.hasFullDiskAccess()
            DispatchQueue.main.async {
                if need != self.needsFullDiskAccess { self.needsFullDiskAccess = need }
                // 权限开好了又被关掉，再提示一次
                if !need { self.fullDiskAccessBannerDismissed = false }
            }
        }
    }

    /// 用一个子进程读只有「完全磁盘访问权限」才能读的系统文件：不会弹窗，
    /// 而且子进程能立刻反映刚在系统设置里打开的权限（不用重启 TuneFree）。
    static func hasFullDiskAccess() -> Bool {
        switch ProcessInfo.processInfo.environment["TUNEFREE_DEBUG_FDA"] {
        case "0": return false
        case "1": return true
        default: break
        }
        for (tool, args) in [("/usr/bin/head", ["-c", "1", "/Library/Application Support/com.apple.TCC/TCC.db"]),
                             ("/bin/ls", [NSHomeDirectory() + "/Library/Safari"])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        }
        return false
    }

    /// 装的 QQ音乐是不是沙盒版（App Store 版）：看它代码签名里的 app-sandbox 权限，不启动它、不弹窗
    static func qqMusicIsSandboxed() -> Bool {
        if let forced = ProcessInfo.processInfo.environment["TUNEFREE_DEBUG_QQ_SANDBOX"] { return forced == "1" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.QQMusicMac") else {
            return false
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// QQ音乐有没有保存自动登录信息：普通版在 ~/Library/Preferences，
    /// 沙盒版（Mac App Store）在自己的容器里。只看有没有 AutoLoginUserInfo，不读内容。
    static func qqLoginDetected() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            "Library/Preferences/com.tencent.QQMusicMac.plist",
            "Library/Containers/com.tencent.QQMusicMac/Data/Library/Preferences/com.tencent.QQMusicMac.plist",
        ].map { home.appendingPathComponent($0) }
        for url in paths {
            if let dict = NSDictionary(contentsOf: url), dict["AutoLoginUserInfo"] != nil { return true }
        }
        return false
    }

    var qqCacheExists: Bool { FileManager.default.fileExists(atPath: Self.qqCacheURL.path) }

    init() {
        let d = UserDefaults.standard
        outputMode = OutputMode(rawValue: d.string(forKey: "outputMode") ?? "") ?? .mp3
        bitrate = d.object(forKey: "bitrate") as? Int ?? 320
        if let saved = d.object(forKey: "parallelJobs") as? Int {
            jobs = min(max(saved, 1), AppModel.maxJobs)
        } else if let old = d.object(forKey: "jobs") as? Int, old != 2 {
            // 旧版每次改任何选项都会把并行数一起存下（默认 2）；不是 2 的才是用户自己调过的
            jobs = min(max(old, 1), AppModel.maxJobs)
        } else {
            jobs = AppModel.defaultJobs
        }
        verify = d.object(forKey: "verify") as? Bool ?? true
        fillTags = d.object(forKey: "fillTags") as? Bool ?? true
        force = d.object(forKey: "force") as? Bool ?? false
        onlineTags = d.object(forKey: "onlineTags") as? Bool ?? true
        finishSound = d.object(forKey: "finishSound") as? Bool ?? true
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearanceMode") ?? "") ?? .system
        writeLrc = d.object(forKey: "writeLrc") as? Bool ?? false
        if let p = d.string(forKey: "outputPath") {
            outputURL = URL(fileURLWithPath: p)
        } else {
            outputURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/TuneFree")
        }
        hasFFmpeg = BackendLocator.ffmpegPath() != nil
        hasQQLogin = AppModel.qqLoginDetected()
        fullDiskAccessBannerDismissed = UserDefaults.standard.bool(forKey: "fdaBannerDismissed")

        bundled = BackendLocator.isBundled
        refreshDiskAccess()
        // 从系统设置切回来时重新检查
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDiskAccess()
        }
    }

    private func save() {
        defaults.set(outputMode.rawValue, forKey: "outputMode")
        defaults.set(bitrate, forKey: "bitrate")
        defaults.set(verify, forKey: "verify")
        defaults.set(fillTags, forKey: "fillTags")
        defaults.set(force, forKey: "force")
        defaults.set(onlineTags, forKey: "onlineTags")
        defaults.set(writeLrc, forKey: "writeLrc")
    }

    // MARK: - 统计

    var totalSize: Int64 { tracks.reduce(0) { $0 + $1.size } }
    var losslessCount: Int { tracks.filter(\.isLossless).count }
    var doneCount: Int { tracks.filter { $0.status == .done || $0.status == .skipped }.count }
    var failedCount: Int { tracks.filter(\.status.isFailure).count }
    var needsLoginCount: Int { tracks.filter(\.needsLogin).count }
    var onlineTaggedCount: Int { tracks.filter(\.onlineTagged).count }

    var isBusy: Bool { phase == .running || phase == .scanning }

    /// 正在处理的那首（后端的 progress 事件报的是刚做完的那首，界面以列表状态为准）
    var activeFileName: String {
        tracks.first(where: { $0.status.isActive })?.fileName ?? currentFile
    }

    /// 整体进度：解密占 35%，转码占 65%
    var overallProgress: Double {
        guard stageTotal > 0 else { return phase == .finished ? 1 : 0 }
        let p = Double(stageDone) / Double(stageTotal)
        return stage == "转码" ? 0.35 + 0.65 * p : 0.35 * p
    }

    // MARK: - 目录

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择放着 .mflac / .mgg 的文件夹（会自动包含子文件夹）"
        if qqCacheExists { panel.directoryURL = Self.qqCacheURL }
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        panel.directoryURL = outputURL
        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url
            defaults.set(url.path, forKey: "outputPath")
        }
    }

    func handleDrop(_ urls: [URL]) -> Bool {
        guard !isBusy, let url = urls.first else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        load(isDir.boolValue ? url : url.deletingLastPathComponent())
        return true
    }

    func reset() {
        guard !isBusy else { return }
        previewProcess?.terminate()
        previewProcess = nil
        inputURL = nil
        tracks = []
        summary = nil
        phase = .idle
    }

    func load(_ url: URL) {
        guard !isBusy else { return }
        inputURL = url
        summary = nil
        lastError = nil
        phase = .scanning
        tracks = []

        // 1) 先在本地快速列出文件，界面立刻有东西
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan(url)
            DispatchQueue.main.async {
                guard self.inputURL == url else { return }
                self.tracks = found
                if found.isEmpty {
                    self.phase = .ready
                    return
                }
                // 2) 再让后端探查尾部结构，补上格式 / 布局 / 是否需要登录态
                self.probe(url)
            }
        }
    }

    private static func scan(_ root: URL) -> [Track] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [Track] = []
        for case let url as URL in e {
            guard Track.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            out.append(Track(path: url.path, size: Int64(size)))
        }
        return out.sorted { $0.path < $1.path }
    }

    private func probe(_ url: URL) {
        var index: [String: Int] = [:]
        for (i, t) in tracks.enumerated() { index[t.path] = i }
        var probed = 0
        previewProcess?.terminate()
        do {
            previewProcess = try BackendProcess(
                args: ["--info", "--json", "-i", url.path] + (onlineTags ? ["--covers"] : []),
                onEvent: { [weak self] ev in
                    guard let self, self.inputURL == url else { return }
                    if ev["event"] as? String == "preview" {
                        // 封面墙：载入时按文件自带歌曲 ID 查到的歌名 / 专辑 / 封面
                        guard let path = ev["input"] as? String, let i = index[path],
                              self.tracks[i].status == .pending else { return }
                        func str(_ key: String) -> String? {
                            let v = ev[key] as? String ?? ""
                            return v.isEmpty ? nil : v
                        }
                        self.tracks[i].metaTitle = str("title") ?? self.tracks[i].metaTitle
                        self.tracks[i].metaArtist = str("artist") ?? self.tracks[i].metaArtist
                        self.tracks[i].album = str("album") ?? self.tracks[i].album
                        self.tracks[i].year = str("year") ?? self.tracks[i].year
                        self.tracks[i].coverPath = str("cover") ?? self.tracks[i].coverPath
                        return
                    }
                    guard ev["event"] as? String == "info",
                          let info = ev["info"] as? [String: Any],
                          let path = info["path"] as? String,
                          let i = index[path] else { return }
                    self.tracks[i].kind = info["kind"] as? String ?? ""
                    self.tracks[i].format = info["format"] as? String ?? ""
                    if let auto = info["ekey_auto"] as? [String: Any] {
                        self.tracks[i].needsLogin = !(auto["available"] as? Bool ?? false)
                    }
                    // 结构探查完就能开始转换，不等封面
                    probed += 1
                    if probed >= self.tracks.count, self.phase == .scanning { self.phase = .ready }
                },
                onExit: { [weak self] _ in
                    guard let self, self.inputURL == url else { return }
                    self.previewProcess = nil
                    if self.phase == .scanning { self.phase = .ready }
                })
        } catch {
            lastError = error.localizedDescription
            phase = .ready
        }
    }

    // MARK: - 运行

    func start() {
        guard let input = inputURL, !tracks.isEmpty, !isBusy else { return }
        for i in tracks.indices {
            tracks[i].status = .pending
            tracks[i].decryptedPath = nil
            tracks[i].outputPath = nil
            // 歌名 / 专辑 / 封面保留载入时查到的，转码阶段的 tags 事件再按最终结果覆盖
            tracks[i].onlineTagged = false
        }
        summary = nil
        logs = []
        stage = "解密"
        stageDone = 0
        stageTotal = tracks.count
        currentFile = ""
        cancelling = false
        startedAt = Date()
        phase = .running

        var args = ["--json", "-i", input.path, "-o", outputURL.path, "-b", "\(bitrate)k", "-j", "\(jobs)"]
        switch outputMode {
        case .mp3: break
        case .both: args.append("--keep-flac")
        case .lossless: args.append("--no-mp3")
        }
        if verify { args.append("--verify") }
        if !fillTags { args.append("--no-tags") }
        if force { args.append("--force") }
        if !onlineTags { args.append("--no-online-tags") }
        if writeLrc { args.append("--lrc") }

        markActive(stage: "解密", file: tracks.first?.fileName ?? "")

        do {
            process = try BackendProcess(
                args: args,
                onEvent: { [weak self] in self?.handle($0) },
                onRawLine: { [weak self] line in self?.appendLog("debug", line) },
                onExit: { [weak self] code in self?.finish(code: code) })
        } catch {
            lastError = error.localizedDescription
            phase = .ready
        }
    }

    func cancel() {
        guard phase == .running else { return }
        cancelling = true
        process?.cancel()
    }

    func terminateIfRunning() {
        process?.terminate()
        previewProcess?.terminate()
    }

    private func appendLog(_ level: String, _ message: String) {
        logs.append(LogLine(level: level, message: message))
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }

    private func indexForSource(_ path: String) -> Int? {
        tracks.firstIndex { $0.path == path }
    }

    private func indexForDecrypted(_ path: String) -> Int? {
        if let i = tracks.firstIndex(where: { $0.decryptedPath == path }) { return i }
        // 跳过的旧产物：用文件名主干对号
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return tracks.firstIndex {
            URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent == stem
        }
    }

    private func markActive(stage: String, file: String) {
        let target: TrackStatus = stage == "转码" ? .transcoding : .decrypting
        let from: TrackStatus = stage == "转码" ? .decrypted : .pending
        // 已在进行中的同阶段条目以外，按「下一个待处理」点亮
        if tracks.contains(where: { $0.status == target }) { return }
        if let i = tracks.firstIndex(where: { $0.status == from }) {
            tracks[i].status = target
        }
        _ = file
    }

    private func handle(_ ev: [String: Any]) {
        guard let type = ev["event"] as? String else { return }
        switch type {
        case "log":
            appendLog(ev["level"] as? String ?? "info", ev["message"] as? String ?? "")
        case "progress":
            let newStage = ev["phase"] as? String ?? stage
            if newStage != stage {
                stage = newStage
            }
            stageDone = ev["done"] as? Int ?? stageDone
            stageTotal = ev["total"] as? Int ?? stageTotal
            currentFile = ev["file"] as? String ?? currentFile
            if stageDone < stageTotal { markActive(stage: stage, file: currentFile) }
        case "decrypt-ok", "decrypt-skip":
            if let src = ev["input"] as? String, let i = indexForSource(src) {
                tracks[i].decryptedPath = ev["output"] as? String
                tracks[i].outputPath = ev["output"] as? String
                tracks[i].status = .decrypted
            }
            markActive(stage: "解密", file: "")
        case "decrypt-fail":
            if let src = ev["input"] as? String, let i = indexForSource(src) {
                tracks[i].status = .failed(ev["message"] as? String ?? "解密失败")
            }
            markActive(stage: "解密", file: "")
        case "transcode-ok", "transcode-skip":
            if let src = ev["input"] as? String, let i = indexForDecrypted(src) {
                if let out = ev["output"] as? String { tracks[i].outputPath = out }
                let alreadyThere = type == "transcode-skip" && ev["reason"] as? String != "no-mp3"
                tracks[i].status = alreadyThere ? .skipped : .done
            }
            stage = "转码"
            markActive(stage: "转码", file: "")
        case "tags":
            if let src = ev["input"] as? String, let i = indexForDecrypted(src) {
                func str(_ key: String) -> String? {
                    let v = ev[key] as? String ?? ""
                    return v.isEmpty ? nil : v
                }
                tracks[i].metaTitle = str("title") ?? tracks[i].metaTitle
                tracks[i].metaArtist = str("artist") ?? tracks[i].metaArtist
                tracks[i].album = str("album") ?? tracks[i].album
                tracks[i].year = str("year") ?? tracks[i].year
                tracks[i].coverPath = str("cover") ?? tracks[i].coverPath
                tracks[i].onlineTagged = ev["online"] as? Bool ?? false
            }
        case "transcode-fail":
            if let src = ev["input"] as? String, let i = indexForDecrypted(src) {
                tracks[i].status = .failed(ev["message"] as? String ?? "转码失败")
            }
            markActive(stage: "转码", file: "")
        case "result":
            guard let r = ev["result"] as? [String: Any] else { return }
            var s = RunSummary()
            s.found = r["files_found"] as? Int ?? 0
            s.decrypted = r["decrypted"] as? Int ?? 0
            s.decryptFailed = r["decrypt_failed"] as? Int ?? 0
            s.decryptSkipped = r["decrypt_skipped"] as? Int ?? 0
            s.mp3OK = r["mp3_ok"] as? Int ?? 0
            s.mp3Failed = r["mp3_failed"] as? Int ?? 0
            s.mp3Skipped = r["mp3_skipped"] as? Int ?? 0
            s.cancelled = r["cancelled"] as? Bool ?? false
            s.elapsed = (r["elapsed"] as? Double) ?? Double(r["elapsed"] as? Int ?? 0)
            for e in (r["errors"] as? [[String: Any]]) ?? [] {
                let path = e["path"] as? String ?? ""
                let msg = e["message"] as? String ?? ""
                s.errors.append((path, e["stage"] as? String ?? "", e["reason"] as? String ?? "", msg))
                // 兼容旧后端：没有 *-fail 事件时，用结果里的错误补标记
                if let i = indexForSource(path) ?? indexForDecrypted(path), !tracks[i].status.isFailure,
                   e["stage"] as? String != "verify" {
                    tracks[i].status = .failed(msg)
                }
            }
            summary = s
        default:
            break
        }
    }

    private func finish(code: Int32) {
        process = nil
        let wasCancelled = code == 130 || cancelling

        // 先在本地算好，再一次性写回：在 withAnimation 里改 phase 会先同步冲刷前面的改动，
        // 偶发导致主界面收不到 phase 的变化（进度条卡住、结果卡片不出现）
        var updated = tracks
        for i in updated.indices {
            switch updated[i].status {
            case .decrypting: updated[i].status = .pending
            case .transcoding: updated[i].status = .decrypted
            default: break
            }
            // 只要无损：解密完就算完成
            if outputMode == .lossless, updated[i].status == .decrypted { updated[i].status = .done }
        }
        var s = summary ?? {
            var s = RunSummary()
            s.found = updated.count
            s.elapsed = Date().timeIntervalSince(startedAt ?? Date())
            if code != 0 && code != 130 {
                s.errors.append(("", "backend", "exit", "后端异常退出（退出码 \(code)），详见日志"))
            }
            return s
        }()
        if wasCancelled { s.cancelled = true }

        tracks = updated
        summary = s
        stageDone = stageTotal
        cancelling = false
        phase = .finished   // 动画由 ContentView 的 .animation(value: phase) 负责

        if !wasCancelled && finishSound {
            NSApp.requestUserAttention(.informationalRequest)
            NSSound(named: "Glass")?.play()
        }
    }

    // MARK: - 打开

    var mp3Folder: URL { outputURL.appendingPathComponent("mp3") }
    var flacFolder: URL { outputURL.appendingPathComponent("flac") }

    func revealOutput() {
        let fm = FileManager.default
        let target: URL
        if outputMode == .lossless, fm.fileExists(atPath: flacFolder.path) {
            target = flacFolder
        } else if fm.fileExists(atPath: mp3Folder.path) {
            target = mp3Folder
        } else {
            target = outputURL
        }
        NSWorkspace.shared.open(target)
    }

    func reveal(_ track: Track) {
        let path = track.outputPath ?? track.path
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: track.path)])
        }
    }
}
