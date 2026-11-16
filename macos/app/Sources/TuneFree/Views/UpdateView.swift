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
                .background(Theme.roundedShape.fill(Theme.overlay(0.04)))
                .overlay(Theme.roundedShape.strokeBorder(Theme.overlay(0.08), lineWidth: 0.8))
            }

            installStatus(release)

            HStack(spacing: 10) {
                if installer.isBusy {
                    if case .downloading = installer.state {
                        Button("取消") { installer.cancel() }
                            .buttonStyle(GhostButtonStyle(height: 38))
                            .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                } else {
                    Button("跳过这个版本") {
                        updater.skip(release)
                        model.dismissSheet()
                    }
                    .buttonStyle(GhostButtonStyle(height: 38))
                    Button("以后再说") { model.dismissSheet() }
                        .buttonStyle(GhostButtonStyle(height: 38))
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if case .failed = installer.state {
                        Button("重新打开下载") {
                            updater.download(release)
                            model.dismissSheet()
                        }
                        .buttonStyle(GhostButtonStyle(height: 38))
                    }
                    Button {
                        installer.install(release)
                    } label: {
                        Label(installer.state == .idle ? "立即更新" : "重试", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 38))
                    .frame(width: 150)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase == .running)
                }
            }
        }
        .padding(26)
    }

    private var installer: UpdateInstaller { updater.installer }

    /// 安装进度 / 结果 / 说明
    @ViewBuilder
    private func installStatus(_ release: ReleaseInfo) -> some View {
        switch installer.state {
        case .idle:
            Text(model.phase == .running
                 ? "正在转换，等转换完成后再更新。"
                 : "点「立即更新」会自动下载适合这台 Mac 的版本（\(Updater.archSuffix == "arm64" ? "Apple 芯片" : "Intel 芯片")），校验无误后替换旧版并重新打开，不用再去系统设置里允许。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading(let fraction):
            progressRow(title: "正在下载… \(Int(fraction * 100))%", value: fraction)
        case .verifying:
            progressRow(title: "正在校验安装包…", value: nil)
        case .installing:
            progressRow(title: "正在安装…", value: nil)
        case .relaunching:
            progressRow(title: "更新完成，正在重新打开 TuneFree…", value: 1)
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.gold)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progressRow(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            if let value {
                GlowBar(progress: value).frame(height: 6)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent2)
            }
        }
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

    /// 只处理标题和 **加粗** / `代码`。不用系统的 Markdown 解析：它在 ** 紧挨中文标点时不认加粗，会把星号原样显示
    private func markdown(_ text: String) -> AttributedString {
        let cleaned = text
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "`", with: "")
        var result = AttributedString()
        for (i, part) in cleaned.components(separatedBy: "**").enumerated() {
            var run = AttributedString(part)
            if i % 2 == 1 { run.font = .system(size: 12.5, weight: .bold) }
            result += run
        }
        return result
    }
}

/// 设置窗口（⌘,）
