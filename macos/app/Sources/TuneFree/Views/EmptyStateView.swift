import SwiftUI

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    var isTargeted: Bool
    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            ZStack {
                // 外圈光晕
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent2.opacity(0.45), .clear],
                                         center: .center, startRadius: 10, endRadius: 120))
                    .frame(width: 240, height: 240)
                    .scaleEffect(isTargeted ? 1.15 : 1)
                    .blur(radius: 10)
                Circle()
                    .strokeBorder(Theme.brandDiagonal, lineWidth: 1.2)
                    .frame(width: 128, height: 128)
                    .opacity(0.6)
                    .rotationEffect(.degrees(appear ? 360 : 0))
                    .animation(.linear(duration: 18).repeatForever(autoreverses: false), value: appear)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 112, height: 112)
                    .overlay(Circle().strokeBorder(Theme.overlay(0.15), lineWidth: 1))
                EqualizerBars(count: 7, active: true, barWidth: 4.5, spacing: 4)
                    .frame(width: 56, height: 42)
            }
            .scaleEffect(appear ? 1 : 0.85)
            .opacity(appear ? 1 : 0)

            VStack(spacing: 12) {
                Text("让每一首歌，回到你手里")
                    .font(.system(size: 34, weight: .bold, design: .default))
                    .tracking(-0.5)
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.textPrimary, Theme.textPrimary.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                Text("把 QQ音乐下载的 .mflac / .mgg 在本机离线解密，转成任何播放器都能打开的 MP3 与 FLAC。")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26)
            .offset(y: appear ? 0 : 12)
            .opacity(appear ? 1 : 0)

            // 拖放区
            VStack(spacing: 16) {
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "folder.badge.plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.textSecondary))
                    .symbolEffect(.bounce, value: isTargeted)
                Text(isTargeted ? "松手即可载入" : "把文件夹拖到这里")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 10) {
                    Button { model.chooseInput() } label: {
                        Label("选择文件夹…", systemImage: "folder")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut("o", modifiers: .command)

                    if model.qqCacheExists {
                        Button { model.load(AppModel.qqCacheURL) } label: {
                            Label("打开 QQ音乐缓存", systemImage: "music.note.house")
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.vertical, 30)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.overlay(isTargeted ? 0.07 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(isTargeted ? AnyShapeStyle(Theme.brandDiagonal) : AnyShapeStyle(Theme.overlay(0.14)),
                                  style: StrokeStyle(lineWidth: isTargeted ? 1.6 : 1, dash: isTargeted ? [] : [6, 6]))
            }
            .padding(.top, 34)
            .offset(y: appear ? 0 : 18)
            .opacity(appear ? 1 : 0)

            HStack(spacing: 26) {
                feature("lock.shield", "完全离线", "不上传任何文件")
                feature("bolt", "约 450 MB/s", "解密几乎瞬间完成")
                feature("tag", "自动补标签", "歌手 · 歌名不丢失")
            }
            .padding(.top, 34)
            .opacity(appear ? 1 : 0)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isTargeted)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.05)) { appear = true }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
