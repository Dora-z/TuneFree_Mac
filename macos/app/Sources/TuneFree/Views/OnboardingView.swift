import SwiftUI

/// 首次打开：使用说明 + 免责声明。同意后才进入主界面；之后可从「帮助」菜单再次查看。
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    /// true = 首次打开（必须勾选同意）；false = 从菜单再次查看
    let firstRun: Bool
    @State private var agreed = false

    static let disclaimerVersion = 1

    var body: some View {
        @Bindable var updater = updater
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 30)
                .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("三步就能用") {
                        VStack(spacing: 8) {
                            step(1, "folder.badge.plus", "选歌", "把放着 .mflac / .mgg 的文件夹拖进窗口，或点「打开 QQ音乐缓存」直接载入下载目录。")
                            step(2, "slider.horizontal.3", "选格式", "右侧选导出位置、输出格式（仅 MP3 / MP3 + 无损 / 仅无损）和 MP3 音质。")
                            step(3, "sparkles", "开始转换", "点「开始转换」（⌘↩），完成后点「在 Finder 中打开」就是成品。")
                        }
                    }

                    section("需要知道") {
                        VStack(alignment: .leading, spacing: 10) {
                            note("person.crop.circle.badge.checkmark",
                                 "新版 QQ音乐下载的歌（列表里标着 musicex）密钥不在文件里，需要这台 Mac 上登录过 QQ音乐（不用开着）。")
                            note("network",
                                 "会连 QQ音乐官方接口取这类歌的密钥，并按歌曲 ID 补全封面、专辑、歌词；只发「这是哪首歌」，不上传任何歌曲。")
                            note("arrow.triangle.2.circlepath",
                                 "已经转好的歌下次会自动跳过；遇到问题点右上角按钮（⌘L）看日志。")
                        }
                    }

                    section("免责声明") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("本工具仅供**个人学习交流**使用，用于解密本机已合法下载的音乐文件，方便在自己拥有的设备上播放。")
                            Text("请勿用于传播、二次分发或商业用途。使用产生的一切法律责任由使用者自行承担。")
                            Text("音乐版权归原权利人所有。本软件基于 MIT 协议开源，按「原样」提供，不提供任何形式的担保。")
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(3)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.gold.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.gold.opacity(0.22), lineWidth: 0.8))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            footer(updater: $updater.autoCheck)
                .padding(.horizontal, 32)
                .padding(.vertical, 18)
        }
        .frame(width: 640, height: 680)
        .background(background)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(firstRun)
    }

    // MARK: - 部件

    private var header: some View {
        HStack(spacing: 16) {
            LogoMark().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(firstRun ? "欢迎使用 TuneFree" : "使用说明与免责声明")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("把 QQ音乐下载的加密歌曲变成任何播放器都能放的 MP3 / FLAC")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func footer(updater autoCheck: Binding<Bool>) -> some View {
        if firstRun {
            VStack(spacing: 14) {
                HStack(spacing: 22) {
                    Toggle(isOn: $agreed) {
                        Text("我已阅读并同意以上免责声明")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .toggleStyle(.checkbox)
                    Toggle(isOn: autoCheck) {
                        Text("自动检查更新")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Button("退出") { NSApp.terminate(nil) }
                        .buttonStyle(GhostButtonStyle(height: 40))
                        .keyboardShortcut(.cancelAction)
                    Button {
                        UserDefaults.standard.set(Self.disclaimerVersion, forKey: "disclaimerAcceptedVersion")
                        model.dismissSheet()
                    } label: {
                        Label("同意并开始使用", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 40))
                    .disabled(!agreed)
                    .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            HStack {
                Toggle(isOn: autoCheck) {
                    Text("自动检查更新")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button("知道了") { model.dismissSheet() }
                    .buttonStyle(PrimaryButtonStyle(height: 38))
                    .frame(width: 140)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var background: some View {
        ZStack {
            Theme.ink
            RadialGradient(colors: [Theme.accent2.opacity(0.28), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.accent.opacity(0.14), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title)
            content()
        }
    }

    private func step(_ index: Int, _ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.brandDiagonal)
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(index). \(title)").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.8))
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
