import AppKit
import Foundation
import Observation

/// GitHub Releases 上的一个版本
struct ReleaseInfo: Equatable {
    let tag: String           // v2.1.3-mac.5
    let version: String       // 2.1.3-mac.5
    let title: String
    let notes: String
    let pageURL: URL
    let downloadURL: URL?     // 对应本机芯片的 DMG
    let publishedAt: Date?
    var sha256: String? = nil // GitHub 给每个发布文件算的 SHA-256（App 内更新用它校验）
}

/// 检查更新：启动时自动查一次（之后每天一次），也可以从菜单手动查。
///
/// 先问 GitHub API（有更新说明和下载地址）；API 连不上或被限流时，
/// 退回 `releases/latest` 的跳转拿到最新 tag，下载地址按发布命名规则拼出来。
@Observable
final class Updater {
    static let repo = "Dora-z/TuneFree_Mac"
    /// 不落盘缓存的会话：检查更新、下载安装包都不在 ~/Library/Caches 里留东西
    static let session = URLSession(configuration: .ephemeral)
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case failed(String)
    }

    var state: State = .idle
    /// 有新版本时顶栏显示的提示（跳过的版本不提示）
    var badge: ReleaseInfo?
    var lastChecked: Date? { defaults.object(forKey: "updateLastChecked") as? Date }

    var autoCheck: Bool {
        didSet { defaults.set(autoCheck, forKey: "autoCheckUpdates"); scheduleTimer() }
    }

    /// 发现新版本时要求弹窗（ContentView 负责展示）
    var onFound: ((ReleaseInfo) -> Void)?

    /// App 内一键更新
    let installer = UpdateInstaller()

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    // MARK: - 版本

    static var currentVersion: String {
        if let v = ProcessInfo.processInfo.environment["TUNEFREE_DEBUG_VERSION"] { return v }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0-dev"
    }

    static var displayVersion: String {
        currentVersion == "0-dev" ? "开发版" : currentVersion
    }

    /// 把 2.1.3-mac.5 拆成 [2, 1, 3, 5] 逐段比较
    static func numbers(_ version: String) -> [Int] {
        var out: [Int] = []
        var current = ""
        for ch in version {
            if ch.isNumber { current.append(ch) } else if !current.isEmpty { out.append(Int(current) ?? 0); current = "" }
        }
        if !current.isEmpty { out.append(Int(current) ?? 0) }
        return out
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = numbers(remote), b = numbers(local)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static var archSuffix: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    // MARK: - 自动检查

    /// 启动时调用：开着自动检查就延迟几秒查一次，之后每 24 小时再查
    func start() {
        scheduleTimer()
        guard autoCheck, Self.currentVersion != "0-dev" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.check(manual: false)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoCheck else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
    }

    /// 某个版本自动更新失败、已恢复旧版：不再自动弹窗推它（手动检查仍会显示）
    func skipVersion(_ version: String) {
        defaults.set(version, forKey: "updateSkippedVersion")
        if badge?.version == version { badge = nil }
    }

    func skip(_ release: ReleaseInfo) {
        defaults.set(release.version, forKey: "updateSkippedVersion")
        if badge == release { badge = nil }
    }

    func download(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    // MARK: - 检查

    func check(manual: Bool) {
        if case .checking = state { return }
        state = .checking
        Task { @MainActor in
            let result = await Self.fetchLatest()
            do {
                self.defaults.set(Date(), forKey: "updateLastChecked")
                switch result {
                case .success(let release):
                    if Self.isNewer(release.version, than: Self.currentVersion) {
                        self.state = .available(release)
                        let skipped = self.defaults.string(forKey: "updateSkippedVersion")
                        if manual || skipped != release.version {
                            self.badge = release
                            self.onFound?(release)
                        }
                    } else {
                        self.state = .upToDate
                        self.badge = nil
                    }
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private static func fetchLatest() async -> Result<ReleaseInfo, Error> {
        do {
            return .success(try await fromAPI())
        } catch {
            do {
                return .success(try await fromRedirect())
            } catch {
                return .failure(NSError(domain: "TuneFree", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "连不上 GitHub，请稍后再试或直接打开发布页查看。",
                ]))
            }
        }
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("TuneFree-Mac/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func fromAPI() async throws -> ReleaseInfo {
        var req = request(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Updater.session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw URLError(.badServerResponse)
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String ?? "").hasSuffix("-\(archSuffix).dmg") }
        let download = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:))
        let digest = (dmg?["digest"] as? String).flatMap { d -> String? in
            d.lowercased().hasPrefix("sha256:") ? String(d.dropFirst(7)).lowercased() : nil
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL
        let published = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(tag: tag, version: versionFromTag(tag), title: json["name"] as? String ?? tag,
                           notes: json["body"] as? String ?? "", pageURL: page,
                           downloadURL: download ?? guessedDownload(tag), publishedAt: published,
                           sha256: digest)
    }

    /// github.com/<repo>/releases/latest 会跳到 /releases/tag/<tag>，不走 API、不受限流
    private static func fromRedirect() async throws -> ReleaseInfo {
        let (_, response) = try await Updater.session.data(for: request(URL(string: "https://github.com/\(repo)/releases/latest")!))
        guard let final = response.url, final.path.contains("/releases/tag/") else {
            throw URLError(.badServerResponse)
        }
        let tag = final.lastPathComponent.removingPercentEncoding ?? final.lastPathComponent
        return ReleaseInfo(tag: tag, version: versionFromTag(tag), title: "TuneFree for Mac \(versionFromTag(tag))",
                           notes: "", pageURL: final, downloadURL: guessedDownload(tag), publishedAt: nil)
    }

    private static func versionFromTag(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// 某个版本的手动下载地址（对应本机芯片的 DMG）
    static func manualDownloadURL(version: String) -> URL? {
        guessedDownload("v" + version)
    }

    private static func guessedDownload(_ tag: String) -> URL? {
        URL(string: "https://github.com/\(repo)/releases/download/\(tag)/TuneFree-\(versionFromTag(tag))-\(archSuffix).dmg")
    }

    /// 发布说明里给界面看的部分：去掉表格、代码块、校验值和页脚
    static func readableNotes(_ notes: String) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in notes.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.hasPrefix("|") { continue }
            if line.hasPrefix("---") || line.contains("Generated with") { break }
            if line.hasPrefix("### 下载") || line.hasPrefix("### 校验") || line.hasPrefix("### 第一次打开") { break }
            if line.hasPrefix("## ") && lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                continue   // 第一行标题就是版本名，弹窗标题里已经有了
            }
            if line.hasPrefix("- ") {
                lines.append("•  " + line.dropFirst(2))
            } else if line.hasPrefix("  ") && !(lines.last ?? "").isEmpty && (lines.last ?? "").hasPrefix("•") {
                lines.append("    " + line.trimmingCharacters(in: .whitespaces))
            } else {
                lines.append(line)
            }
        }
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
