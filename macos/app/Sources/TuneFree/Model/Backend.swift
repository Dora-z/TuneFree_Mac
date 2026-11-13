import Foundation

/// 找到并驱动 Python 后端（`--json` 事件流）。
///
/// 查找顺序：
/// 1. App 包内 `Contents/Resources/TuneFreeBackend/TuneFreeBackend`（发布版，自带 Python + ffmpeg）
/// 2. 环境变量 `TUNEFREE_BACKEND_SRC` 指向的源码目录（含 main.py）
/// 3. 从可执行文件位置往上找 `main.py + tunefree_backend/`（开发时 `swift run`）
struct BackendLocator {
    enum Kind { case bundled(URL), source(URL) }

    static func locate() -> Kind? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let bin = res.appendingPathComponent("TuneFreeBackend/TuneFreeBackend")
            if fm.isExecutableFile(atPath: bin.path) { return .bundled(bin) }
        }
        if let env = ProcessInfo.processInfo.environment["TUNEFREE_BACKEND_SRC"] {
            let url = URL(fileURLWithPath: env)
            if fm.fileExists(atPath: url.appendingPathComponent("main.py").path) { return .source(url) }
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            if fm.fileExists(atPath: dir.appendingPathComponent("main.py").path),
               fm.fileExists(atPath: dir.appendingPathComponent("tunefree_backend").path) {
                return .source(dir)
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func command(_ args: [String]) -> (URL, [String])? {
        switch locate() {
        case .bundled(let bin)?:
            return (bin, args)
        case .source(let dir)?:
            return (URL(fileURLWithPath: "/usr/bin/env"),
                    ["python3", dir.appendingPathComponent("main.py").path] + args)
        case nil:
            return nil
        }
    }

    static var isBundled: Bool {
        if case .bundled? = locate() { return true }
        return false
    }

    /// 给界面上的状态指示用：内置 ffmpeg 或系统 ffmpeg
    static func ffmpegPath() -> String? {
        let fm = FileManager.default
        if case .bundled(let bin)? = locate() {
            let ff = bin.deletingLastPathComponent().appendingPathComponent("ffmpeg").path
            if fm.isExecutableFile(atPath: ff) { return ff }
        }
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }
}

/// 起一个后端进程，逐行把 JSON 事件丢回主线程。
final class BackendProcess {
    private let process = Process()
    private var buffer = Data()
    private let onEvent: ([String: Any]) -> Void
    private let onExit: (Int32) -> Void
    private let onRawLine: (String) -> Void

    init(args: [String],
         onEvent: @escaping ([String: Any]) -> Void,
         onRawLine: @escaping (String) -> Void = { _ in },
         onExit: @escaping (Int32) -> Void) throws {
        self.onEvent = onEvent
        self.onExit = onExit
        self.onRawLine = onRawLine

        guard let (exe, fullArgs) = BackendLocator.command(args) else {
            throw NSError(domain: "TuneFree", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到后端程序（TuneFreeBackend）"])
        }
        process.executableURL = exe
        process.arguments = fullArgs

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["LANG"] = env["LANG"] ?? "zh_CN.UTF-8"
        // 从 Finder 启动的 App 拿到的 PATH 很短，补上 Homebrew 的位置
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + extra
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let s = String(line)
                DispatchQueue.main.async { self.onRawLine(s) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            // 把管道里剩下的读干净
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            guard let self else { return }
            if !rest.isEmpty { self.consume(rest) }
            self.flushTail()
            let code = proc.terminationStatus
            DispatchQueue.main.async { self.onExit(code) }
        }
        try process.run()
    }

    private let lock = NSLock()

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines { dispatch(line) }
    }

    private func flushTail() {
        lock.lock()
        let tail = buffer
        buffer.removeAll()
        lock.unlock()
        if !tail.isEmpty { dispatch(tail) }
    }

    private func dispatch(_ line: Data) {
        guard !line.isEmpty else { return }
        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            DispatchQueue.main.async { self.onEvent(obj) }
        } else if let s = String(data: line, encoding: .utf8) {
            DispatchQueue.main.async { self.onRawLine(s) }
        }
    }

    /// 发 SIGINT：后端会把当前文件做完再退出（退出码 130）
    func cancel() {
        if process.isRunning { process.interrupt() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
