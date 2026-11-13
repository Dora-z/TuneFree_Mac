import AppKit
import Foundation
import Observation
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

enum SheetKind: String, Identifiable {
    case onboarding   // 首次打开：使用说明 + 免责声明（必须同意）
    case about        // 从菜单再次查看说明
    case update       // 检查更新结果
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
    var jobs: Int { didSet { save() } }
    var verify: Bool { didSet { save() } }
    var fillTags: Bool { didSet { save() } }
    var force: Bool { didSet { save() } }
    var onlineTags: Bool { didSet { save() } }
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
    private let defaults = UserDefaults.standard

    static let qqCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iQmc")

    var qqCacheExists: Bool { FileManager.default.fileExists(atPath: Self.qqCacheURL.path) }

    init() {
        let d = UserDefaults.standard
        outputMode = OutputMode(rawValue: d.string(forKey: "outputMode") ?? "") ?? .mp3
        bitrate = d.object(forKey: "bitrate") as? Int ?? 320
        jobs = d.object(forKey: "jobs") as? Int ?? 2
        verify = d.object(forKey: "verify") as? Bool ?? true
        fillTags = d.object(forKey: "fillTags") as? Bool ?? true
        force = d.object(forKey: "force") as? Bool ?? false
        onlineTags = d.object(forKey: "onlineTags") as? Bool ?? true
        writeLrc = d.object(forKey: "writeLrc") as? Bool ?? false
        if let p = d.string(forKey: "outputPath") {
            outputURL = URL(fileURLWithPath: p)
        } else {
            outputURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/TuneFree")
        }
        hasFFmpeg = BackendLocator.ffmpegPath() != nil
        hasQQLogin = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.tencent.QQMusicMac.plist").path)
        bundled = BackendLocator.isBundled
    }

    private func save() {
        defaults.set(outputMode.rawValue, forKey: "outputMode")
        defaults.set(bitrate, forKey: "bitrate")
        defaults.set(jobs, forKey: "jobs")
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
        do {
            process = try BackendProcess(
                args: ["--info", "--json", "-i", url.path],
                onEvent: { [weak self] ev in
                    guard let self, self.inputURL == url,
                          ev["event"] as? String == "info",
                          let info = ev["info"] as? [String: Any],
                          let path = info["path"] as? String,
                          let i = index[path] else { return }
                    self.tracks[i].kind = info["kind"] as? String ?? ""
                    self.tracks[i].format = info["format"] as? String ?? ""
                    if let auto = info["ekey_auto"] as? [String: Any] {
                        self.tracks[i].needsLogin = !(auto["available"] as? Bool ?? false)
                    }
                },
                onExit: { [weak self] _ in
                    guard let self, self.inputURL == url else { return }
                    self.process = nil
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
            tracks[i].metaTitle = nil
            tracks[i].metaArtist = nil
            tracks[i].album = nil
            tracks[i].year = nil
            tracks[i].coverPath = nil
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

    func terminateIfRunning() { process?.terminate() }

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
                tracks[i].metaTitle = str("title")
                tracks[i].metaArtist = str("artist")
                tracks[i].album = str("album")
                tracks[i].year = str("year")
                tracks[i].coverPath = str("cover")
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

        if !wasCancelled {
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
