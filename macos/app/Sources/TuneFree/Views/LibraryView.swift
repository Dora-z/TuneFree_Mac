import SwiftUI

/// 选好目录后的主区域：头部信息 + 曲目列表
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", lossless = "无损", failed = "失败"
        var id: String { rawValue }
    }

    var visible: [Track] {
        switch filter {
        case .all: return model.tracks
        case .lossless: return model.tracks.filter(\.isLossless)
        case .failed: return model.tracks.filter(\.status.isFailure)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .padding(.bottom, 18)

            if model.tracks.isEmpty && model.phase != .scanning {
                emptyFolder
            } else {
                listHeader
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if model.tracks.isEmpty {
                            ForEach(0..<6, id: \.self) { _ in SkeletonRow() }
                        }
                        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, track in
                            TrackRow(track: track, index: idx + 1)
                        }
                    }
                    .padding(.horizontal, 18)
                    // 给底部的进度条 / 结果卡片让出位置，最后几行也能滚出来
                    .padding(.bottom, model.phase == .finished ? 360 : 130)
                }
                .scrollIndicators(.never)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.02),
                                             .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.brandDiagonal)
                    .frame(width: 68, height: 68)
                    .shadow(color: Theme.accent2.opacity(0.5), radius: 18, y: 8)
                Image(systemName: "folder.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "来源文件夹")
                Text(model.inputURL?.lastPathComponent ?? "")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(model.inputURL.map { abbreviate($0.path) } ?? "")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            HStack(spacing: 22) {
                stat(value: "\(model.tracks.count)", label: "曲目")
                divider
                stat(value: model.totalSize.byteString, label: "总大小")
                divider
                stat(value: "\(model.losslessCount)", label: "无损")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .fixedSize()                 // 窗口窄的时候让文件夹名去截断，统计数字不换行
            .glass(radius: 16)

            Button { model.chooseInput() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(GhostButtonStyle())
            .help("更换文件夹")
            .disabled(model.isBusy)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 28)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Filter.allCases) { f in
                    let count = f == .all ? model.tracks.count : (f == .lossless ? model.losslessCount : model.failedCount)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { filter = f }
                    } label: {
                        HStack(spacing: 5) {
                            Text(f.rawValue)
                            Text("\(count)").foregroundStyle(Theme.textTertiary).monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(filter == f ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if filter == f {
                                Capsule().fill(Theme.overlay(0.1))
                                    .overlay(Capsule().strokeBorder(Theme.overlay(0.12), lineWidth: 0.8))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(f == .failed && model.failedCount == 0 ? 0.45 : 1)
                }
            }
            .padding(3)
            .background(Capsule().fill(Theme.well))

            Spacer()

            if model.phase == .scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("正在识别文件结构…").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
                .transition(.opacity)
            } else if model.needsLoginCount > 0 {
                Label("\(model.needsLoginCount) 首需要 QQ音乐登录态", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.gold)
                    .help("musicex 格式的文件密钥不在文件里，需要本机登录过 QQ音乐")
            }
        }
    }

    private var emptyFolder: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("这个文件夹里没有找到加密歌曲")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("支持 .mflac · .mgg · .qmcflac · .qmcogg 等，会自动查找子文件夹")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            Button("换一个文件夹…") { model.chooseInput() }
                .buttonStyle(GhostButtonStyle())
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - 行

struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let index: Int
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            Text(String(format: "%02d", index))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22, alignment: .trailing)

            Artwork(track: track)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(track.displayArtist.isEmpty ? "未知歌手" : track.displayArtist)
                        .lineLimit(1)
                    if let album = track.album, !album.isEmpty {
                        Text("·  \(album)\(track.year.map { " · \($0)" } ?? "")")
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if case .failed(let msg) = track.status {
                        Text("· \(msg)")
                            .foregroundStyle(Theme.danger.opacity(0.9))
                            .lineLimit(1)
                            .help(msg)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Badge(text: track.displayFormat,
                      color: track.isLossless ? Theme.gold : Theme.accent)
                if !track.kind.isEmpty {
                    Badge(text: track.kindLabel, color: track.needsLogin ? Theme.gold : Theme.textTertiary)
                }
            }

            Text(track.size.byteString)
                .font(.system(size: 11.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 64, alignment: .trailing)

            StatusIndicator(status: track.status)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(track.status.isActive ? Theme.overlay(0.085) : Theme.overlay(hover ? 0.05 : 0))
                .overlay {
                    if track.status.isActive {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.brand.opacity(0.6), lineWidth: 1)
                    }
                }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.reveal(track) }
        .contextMenu {
            Button("在 Finder 中显示") { model.reveal(track) }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(track.outputPath ?? track.path, forType: .string)
            }
        }
        .animation(.easeOut(duration: 0.2), value: track.status)
    }
}

struct Artwork: View {
    let track: Track
    var size: CGFloat = 38

    var body: some View {
        let c1 = Color(hue: track.hue, saturation: 0.55, brightness: 0.85)
        let c2 = Color(hue: (track.hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.45)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let path = track.coverPath, let image = CoverCache.image(path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity)
            } else if track.status.isActive {
                EqualizerBars(count: 4, active: true, color: AnyShapeStyle(Color.white), barWidth: 2.5, spacing: 2)
                    .frame(width: 18, height: 16)
            } else {
                Text(track.initials)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.6))
        .shadow(color: c2.opacity(0.4), radius: 6, y: 3)
    }
}

/// 封面缩略图缓存（同一张专辑封面多首歌共用，不重复解码 800×800 的 JPEG）
enum CoverCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let full = NSImage(contentsOfFile: path) else { return nil }
        let side: CGFloat = 96
        let thumb = NSImage(size: NSSize(width: side, height: side))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        thumb.unlockFocus()
        cache.setObject(thumb, forKey: path as NSString)
        return thumb
    }
}

struct StatusIndicator: View {
    let status: TrackStatus

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .pending:
                Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.2).frame(width: 10, height: 10)
                Text("待处理").foregroundStyle(Theme.textTertiary)
            case .decrypting:
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text("解密中").foregroundStyle(Theme.accent)
            case .decrypted:
                Image(systemName: "lock.open.fill").foregroundStyle(Theme.accent2)
                Text("已解密").foregroundStyle(Theme.textSecondary)
            case .transcoding:
                ProgressView().controlSize(.mini).tint(Theme.accent2)
                Text("转码中").foregroundStyle(Theme.accent2)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text("完成").foregroundStyle(Theme.success)
            case .skipped:
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.success.opacity(0.7))
                Text("已存在").foregroundStyle(Theme.textSecondary)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                Text("失败").foregroundStyle(Theme.danger)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

private struct SkeletonRow: View {
    @State private var shimmer = false
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10).fill(Theme.overlay(0.06)).frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.overlay(0.07)).frame(width: 180, height: 10)
                RoundedRectangle(cornerRadius: 4).fill(Theme.overlay(0.05)).frame(width: 110, height: 8)
            }
            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 9)
        .opacity(shimmer ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(), value: shimmer)
        .onAppear { shimmer = true }
    }
}
