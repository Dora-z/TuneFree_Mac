import SwiftUI

/// 检查更新的结果：有新版本 / 已是最新 / 检查失败
struct UpdateView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch updater.state {
            case .available(let release):
                available(release)
            case .checking, .idle:
                simple(symbol: nil, title: "正在检查更新…", detail: "当前版本 \(Updater.displayVersion)")
            case .upToDate:
                simple(symbol: "checkmark.seal.fill", title: "已是最新版本",
                       detail: "当前版本 \(Updater.displayVersion)，没有发现更新。")
            case .failed(let message):
                simple(symbol: "wifi.exclamationmark", title: "检查更新失败", detail: message, showPage: true)
            }
        }
        .frame(width: 520)
        .background(ZStack {
            Theme.ink
            RadialGradient(colors: [Theme.accent2.opacity(0.25), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
        })
        .preferredColorScheme(.dark)
    }

    private func available(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                LogoMark().frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现新版本 \(release.version)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("当前版本 \(Updater.displayVersion)\(release.publishedAt.map { " · 发布于 " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            let notes = Updater.readableNotes(release.notes)
            if !notes.isEmpty {
                ScrollView {
                    Text(markdown(notes))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
            }

            Text("下载的是适合这台 Mac 的安装包（\(Updater.archSuffix == "arm64" ? "Apple 芯片" : "Intel 芯片")）。打开后把新版 TuneFree 拖进「应用程序」替换旧版即可。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("跳过这个版本") {
                    updater.skip(release)
                    model.dismissSheet()
                }
                .buttonStyle(GhostButtonStyle(height: 38))
                Button("以后再说") { model.dismissSheet() }
                    .buttonStyle(GhostButtonStyle(height: 38))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    updater.download(release)
                    model.dismissSheet()
                } label: {
                    Label("下载新版本", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle(height: 38))
                .frame(width: 170)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
    }

    private func simple(symbol: String?, title: String, detail: String, showPage: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Theme.brand)
                    } else {
                        ProgressView().controlSize(.regular)
                    }
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if showPage {
                    Button("打开发布页") { NSWorkspace.shared.open(Updater.releasesURL); model.dismissSheet() }
                        .buttonStyle(GhostButtonStyle(height: 36))
                }
                Spacer()
                Button("好") { model.dismissSheet() }
                    .buttonStyle(PrimaryButtonStyle(height: 36))
                    .frame(width: 110)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let cleaned = text
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }
}

/// 设置窗口（⌘,）
struct SettingsView: View {
    @Environment(Updater.self) private var updater
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                Toggle("自动检查更新", isOn: $updater.autoCheck)
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text(Updater.displayVersion).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let last = updater.lastChecked {
                    HStack {
                        Text("上次检查")
                        Spacer()
                        Text(last.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("立即检查更新") {
                        model.sheet = .update
                        updater.check(manual: true)
                    }
                }
            } header: {
                Text("更新")
            }
            Section {
                HStack {
                    Button("使用说明与免责声明…") { model.sheet = .about }
                    Spacer()
                    Button("在 GitHub 上查看") { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)")!) }
                }
            } header: {
                Text("关于")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
