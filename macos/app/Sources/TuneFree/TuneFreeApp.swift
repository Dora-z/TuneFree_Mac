import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` 时没有 .app 包，手动切成前台 App
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 把文件夹拖到 Dock 图标上 / `open -a TuneFree 某目录`
    private var pendingURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { pendingURLs = urls; return }
        _ = model.handleDrop(urls)
    }

    func attach(_ model: AppModel) {
        self.model = model
        if !pendingURLs.isEmpty {
            _ = model.handleDrop(pendingURLs)
            pendingURLs = []
        }
        DebugHooks.install(model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.terminateIfRunning()
    }
}

/// 开发用：用环境变量驱动界面并把窗口截成 PNG（不需要屏幕录制权限）。
///   TUNEFREE_DEBUG_OPEN=<目录>        启动后自动载入
///   TUNEFREE_DEBUG_OUTPUT=<目录>      本次运行的导出目录（不写入偏好设置）
///   TUNEFREE_DEBUG_AUTORUN=1          载入完成后自动开始
///   TUNEFREE_DEBUG_ONBOARDING=1       强制弹出首次说明
///   TUNEFREE_DEBUG_VERSION=<版本>     假装当前是这个版本（测检查更新）
///   TUNEFREE_DEBUG_SNAPSHOT=<目录>    每秒截一张窗口图，共 TUNEFREE_DEBUG_SHOTS 张（默认 8）
enum DebugHooks {
    static func install(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let out = env["TUNEFREE_DEBUG_OUTPUT"] {
            model.outputURL = URL(fileURLWithPath: out)
        }
        if let dir = env["TUNEFREE_DEBUG_OPEN"] {
            model.load(URL(fileURLWithPath: dir))
        }
        if env["TUNEFREE_DEBUG_AUTORUN"] == "1" {
            func waitAndStart() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if model.phase == .ready { model.start() } else { waitAndStart() }
                }
            }
            waitAndStart()
        }
        if let out = env["TUNEFREE_DEBUG_SNAPSHOT"] {
            let shots = Int(env["TUNEFREE_DEBUG_SHOTS"] ?? "") ?? 8
            for i in 0..<shots {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i)) {
                    snapshot(to: URL(fileURLWithPath: out).appendingPathComponent(String(format: "shot-%02d.png", i)))
                    if i == shots - 1 { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// 走窗口服务器截自己的窗口（能截到动画的真实帧）；拿不到时退回 cacheDisplay
    static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") {
            let fn = unsafeBitCast(sym, to: Fn.self)
            // 有弹出的 sheet 时：以 sheet 为顶，连同下面的主窗口一起截（主窗口范围内）
            var image: CGImage?
            if let sheet = window.attachedSheet, let screen = NSScreen.screens.first {
                let f = window.frame
                let rect = CGRect(x: f.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
                image = fn(rect, 2 | 8, UInt32(sheet.windowNumber), 1)?.takeRetainedValue()
            }
            // .null rect = 窗口自身边界；optionIncludingWindow = 8；boundsIgnoreFraming = 1
            if let img = image ?? fn(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() {
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

@main
struct TuneFreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        WindowGroup("TuneFree") {
            ContentView()
                .environment(model)
                .environment(updater)
                .onAppear {
                    delegate.attach(model)
                    startup()
                }
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { checkForUpdates() }
            }
            CommandGroup(replacing: .help) {
                Button("使用说明与免责声明") { model.sheet = .about }
                Button("TuneFree 主页") { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)")!) }
                Button("所有版本") { NSWorkspace.shared.open(Updater.releasesURL) }
            }
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") { model.chooseInput() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isBusy)
            }
            CommandGroup(after: .newItem) {
                Button("开始转换") { model.start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.tracks.isEmpty || model.isBusy)
                Button("停止") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.phase != .running)
                Divider()
                Button("在 Finder 中显示导出目录") { model.revealOutput() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }
    }

    private func checkForUpdates() {
        model.sheet = .update
        updater.check(manual: true)
    }

    /// 启动：首次打开先弹说明；自动检查更新在后台进行，发现新版本再提示
    private func startup() {
        let env = ProcessInfo.processInfo.environment
        let debugRun = env.keys.contains { $0.hasPrefix("TUNEFREE_DEBUG_") }
        if env["TUNEFREE_DEBUG_ONBOARDING"] == "1" || (!debugRun && model.needsOnboarding) {
            model.sheet = .onboarding
        }
        updater.onFound = { [model] _ in model.presentUpdateIfQuiet() }
        if !debugRun || env["TUNEFREE_DEBUG_VERSION"] != nil {
            updater.start()
        }
    }
}

/// 让窗口内容延伸到标题栏、背景可拖动
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // 空的 unified 工具栏把标题栏撑到 52pt，红绿灯与自绘顶栏垂直居中对齐
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "main")
                toolbar.showsBaselineSeparator = false
                window.toolbar = toolbar
            }
            window.toolbarStyle = .unified
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(red: 0.035, green: 0.039, blue: 0.067, alpha: 1)
            window.appearance = NSAppearance(named: .darkAqua)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
