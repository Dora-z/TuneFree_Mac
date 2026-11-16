import SwiftUI

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var isTargeted: Bool

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width < 1100 ? 48 : 64
            let contentWidth = min(geometry.size.width - inset * 2, 1240)
            let coverWidth = min(contentWidth * 0.28, max(210, (geometry.size.height - 190) / 1.5), 320)
            let titleSize = min(76, max(48, contentWidth * 0.062))
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                HStack(alignment: .center, spacing: 56) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("让喜欢的歌，\n随处可听。")
                            .font(.system(size: titleSize, weight: .heavy))
                            .tracking(-1.5)
                            .lineSpacing(4)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 28)
                        Text("将 QQ音乐下载的 .mflac / .mgg 等文件\n转换为 MP3 或无损音频。")
                            .font(.system(size: geometry.size.width < 1100 ? 17 : 20))
                            .lineSpacing(6)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 36)
                        HStack(spacing: 12) {
                            Button { model.chooseInput() } label: {
                                Text("选择文件或文件夹…")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SolidButtonStyle(height: 48))
                            .keyboardShortcut("o", modifiers: .command)
                            if model.qqCacheExists {
                                Button { model.load(AppModel.qqCacheURL) } label: {
                                    Text("打开 QQ音乐下载目录")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(GhostButtonStyle(height: 48))
                                .overlay(Theme.roundedShape
                                    .strokeBorder(Theme.textSecondary, lineWidth: 1))
                            }
                        }
                        .padding(.bottom, 22)
                        Label(isTargeted ? "松手即可添加歌曲" : "也可以将歌曲或文件夹拖到这里",
                              systemImage: "arrow.down.doc")
                            .font(.system(size: 13))
                            .foregroundStyle(isTargeted ? Theme.accent2 : Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 18) {
                        Text("你的音乐一角")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        album(0, side: coverWidth)
                        HStack(alignment: .top, spacing: 18) {
                            album(1, side: (coverWidth - 18) / 2)
                            album(2, side: (coverWidth - 18) / 2)
                        }
                    }
                    .frame(width: coverWidth)
                }
                Spacer(minLength: 24)
                Spacer().frame(height: 28)
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isTargeted {
                    Theme.roundedShape
                        .strokeBorder(Theme.accent2, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
        }
         .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            model.loadHomeCoversIfNeeded()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) }
                catch { return }
                guard !Task.isCancelled else { return }
                model.loadHomeCoversIfNeeded(refresh: true)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isTargeted)
    }

    private func album(_ index: Int, side: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
          VStack(alignment: .leading, spacing: 8) {
            sleeve(index, side: side)
            VStack(alignment: .leading, spacing: 3) {
                Text(index < model.homeCovers.count ? model.homeCovers[index].displayTitle : "等待发现好音乐")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(index < model.homeCovers.count ? model.homeCovers[index].displayArtist : "QQ音乐下载目录")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .lineLimit(1)
        }
          .frame(width: side, alignment: .leading)
          .id(index < model.homeCovers.count ? model.homeCovers[index].id : "placeholder-\(index)")
          .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9),
                   value: model.homeCovers.map(\.id))
    }

    @ViewBuilder
    private func sleeve(_ index: Int, side: CGFloat) -> some View {
        let tracks = model.homeCovers
        Group {
            if index < tracks.count {
                CoverArt(track: tracks[index])
                    .help([tracks[index].displayTitle, tracks[index].displayArtist].filter { !$0.isEmpty }.joined(separator: " · "))
                    .accessibilityLabel("封面：\(tracks[index].displayTitle)")
            } else {
                ZStack {
                    Theme.panel
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: side * 0.55, weight: .ultraLight))
                        .foregroundStyle(Theme.accent2.opacity(0.35))
                }
                .accessibilityLabel("默认唱片封面")
            }
        }
        .frame(width: side, height: side)
        .clipShape(Theme.roundedShape)
        .overlay(Theme.roundedShape.strokeBorder(Theme.coverEdge, lineWidth: 0.6))
    }
}
