import AppKit
import SwiftUI

/// 设置页（顶栏齿轮 / ⌘,）：版本与仓库、检查更新、外观、运行环境、缓存、帮助
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64?
    @State private var copied = false

    private static let repoURL = URL(string: "https://github.com/\(Updater.repo)")!

    var body: some View {
        @Bindable var model = model
        @Bindable var updater = updater
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    about

                    group("更新") {
                        ToggleRow(title: "自动检查更新", detail: "启动时和之后每天检查一次", isOn: $updater.autoCheck)
                        divider
                        updateRow
                    }

                    group("通用") {
                        HStack {
                            label("外观", "也可以跟随系统自动切换")
                            Spacer()
                            PillPicker(options: AppearanceMode.allCases, selection: $model.appearance) { $0.title }
                                .frame(width: 210)
                        }
                        .padding(.vertical, 6)
                        divider
                        ToggleRow(title: "完成时提醒", detail: "转换结束后播放提示音，程序坞图标跳一下", isOn: $model.finishSound)
                    }

                    group("运行环境") {
                        statusRow("QQ音乐登录态", ok: model.hasQQLogin,
                                  okText: "已检测到", badText: "未检测到",
                                  detail: "新版 musicex 格式的歌要靠它取密钥")
                        divider
                        statusRow("转码引擎", ok: model.hasFFmpeg,
                                  okText: "ffmpeg 就绪", badText: "缺少 ffmpeg",
                                  detail: "App 自带，用来转成 MP3")
                        if model.needsFullDiskAccess {
                            divider
                            HStack {
                                label("完全磁盘访问权限", "App Store 版 QQ音乐需要它才能读到歌曲和登录信息")
                                Spacer()
                                Button("打开系统设置") { AppModel.openFullDiskAccessSettings() }
                                    .buttonStyle(GhostButtonStyle(height: 28))
                            }
                            .padding(.vertical, 6)
                        }
                    }

                    group("存储") {
                        HStack {
                            label("封面缓存", "补全标签时下载的专辑封面，下次不用再联网")
                            Spacer()
                            Text(cacheSize.map { $0.byteString } ?? "…")
                                .font(.system(size: 12, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                            Button("清空") { clearCache() }
                                .buttonStyle(GhostButtonStyle(height: 28))
                                .disabled((cacheSize ?? 0) == 0 || model.isBusy)
                        }
                        .padding(.vertical, 6)
                    }

                    group("帮助") {
                        linkRow("使用说明与免责声明", symbol: "book") { model.sheet = .about }
                        divider
                        linkRow("反馈问题", symbol: "exclamationmark.bubble") {
                            NSWorkspace.shared.open(Self.repoURL.appendingPathComponent("issues"))
                        }
                        divider
                        linkRow("所有版本与更新说明", symbol: "clock.arrow.circlepath") {
                            NSWorkspace.shared.open(Updater.releasesURL)
                        }
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.never)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack {
                Text("全程本地处理，不上传你的歌曲")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(SolidButtonStyle(height: 30))
                    .frame(width: 88)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 680)
        .background(ZStack {
            Theme.ink
            RadialGradient(colors: [Theme.accent2.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 380)
        })
        .onAppear { refreshCacheSize() }
        .onExitCommand { dismiss() }
    }

    // MARK: 关于：图标、版本、仓库

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                LogoMark().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TuneFree for Mac")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text("版本 \(Updater.displayVersion)")
                            .textSelection(.enabled)
                        Text("·")
                        Text(Updater.archSuffix == "arm64" ? "Apple 芯片" : "Intel")
                    }
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Link(destination: Self.repoURL) {
                    Text("github.com/\(Updater.repo)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent2)
                        .lineLimit(1)
                        .fixedSize()
                }
                .help("在浏览器里打开仓库")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.repoURL.absoluteString, forType: .string)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Theme.success : Theme.textSecondary)
                }
                .buttonStyle(IconButtonStyle())
                .help(copied ? "已拷贝" : "拷贝仓库地址")
                Button {
                    NSWorkspace.shared.open(Self.repoURL)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(IconButtonStyle())
                .help("在浏览器里打开")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))

            Text("基于 zksbx/TuneFree（Windows 版）· MIT 协议")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .background(card)
    }

    // MARK: 检查更新

    private var updateRow: some View {
        HStack(spacing: 10) {
            Group {
                switch updater.state {
                case .checking:
                    ProgressView().controlSize(.small)
                case .available:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent2)
                case .upToDate:
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
                case .failed:
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.gold)
                case .idle:
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.system(size: 15))
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(updateTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(updateDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            if case .available = updater.state {
                Button("查看新版本") { model.sheet = .update }
                    .buttonStyle(SolidButtonStyle(height: 28))
                    .frame(width: 100)
            } else {
                Button("检查更新") { updater.check(manual: false) }
                    .buttonStyle(GhostButtonStyle(height: 28))
                    .disabled(updater.state == .checking || Updater.currentVersion == "0-dev")
                    .help(Updater.currentVersion == "0-dev" ? "开发版不检查更新" : "")
            }
        }
        .padding(.vertical, 6)
    }

    private var updateTitle: String {
        switch updater.state {
        case .checking: return "正在检查…"
        case .available(let r): return "发现新版本 \(r.version)"
        case .upToDate: return "已是最新版本"
        case .failed: return "检查失败"
        case .idle: return "当前版本 \(Updater.displayVersion)"
        }
    }

    private var updateDetail: String {
        if case .failed(let message) = updater.state { return message }
        if let last = updater.lastChecked {
            return "上次检查：" + last.formatted(date: .abbreviated, time: .shortened)
        }
        return "还没有检查过"
    }

    // MARK: 缓存

    private static var coverCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/TuneFree/covers")
    }

    private func refreshCacheSize() {
        DispatchQueue.global(qos: .utility).async {
            let size = Self.folderSize(Self.coverCacheURL)
            DispatchQueue.main.async { cacheSize = size }
        }
    }

    private func clearCache() {
        let url = Self.coverCacheURL
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for item in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
            let size = Self.folderSize(url)
            DispatchQueue.main.async { cacheSize = size }
        }
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: 小部件

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelEdge, lineWidth: 0.8))
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(card)
        }
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func statusRow(_ title: String, ok: Bool, okText: String, badText: String, detail: String) -> some View {
        HStack {
            label(title, detail)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(ok ? Theme.success : Theme.gold).frame(width: 7, height: 7)
                Text(ok ? okText : badText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ok ? Theme.textSecondary : Theme.gold)
            }
        }
        .padding(.vertical, 6)
    }

    private func linkRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
