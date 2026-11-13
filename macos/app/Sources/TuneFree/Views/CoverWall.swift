import AppKit
import CoreImage
import SwiftUI

/// 封面墙：选好文件夹后的主区域。每首歌一张封面，转换状态直接画在封面上。
struct CoverWallView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var followedID: String?

    /// 按列表顺序跟随当前阶段，避免并行完成事件把焦点拉来拉去。
    private var followTarget: String? {
        guard model.phase == .running, !model.cancelling else { return nil }
        let status: TrackStatus = model.stage == "转码" ? .transcoding : .decrypting
        return visible.first(where: { $0.status == status })?.id
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", lossless = "无损", failed = "失败"
        var id: String { rawValue }
    }

    private var visible: [Track] {
        switch filter {
        case .all: return model.tracks
        case .lossless: return model.tracks.filter(\.isLossless)
        case .failed: return model.tracks.filter(\.status.isFailure)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 26)
                .padding(.top, 2)
                .padding(.bottom, 16)

            if model.tracks.isEmpty && model.phase != .scanning {
                emptyFolder
            } else {
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 176), spacing: 20, alignment: .top)],
                                      alignment: .leading, spacing: 24) {
                                if model.tracks.isEmpty {
                                    ForEach(0..<12, id: \.self) { _ in SkeletonTile() }
                                }
                                ForEach(visible) { track in
                                    CoverTile(track: track)
                                        .id(track.id)
                                        .background(GeometryReader { geometry in
                                            Color.clear.preference(key: CoverFramePreference.self,
                                                value: [track.id: geometry.frame(in: .named("coverViewport"))])
                                        })
                                }
                            }
                            .padding(.horizontal, 26)
                            .padding(.top, 4)
                            .padding(.bottom, 28)
                            .background(OverlayScroller())
                        }
                        .coordinateSpace(name: "coverViewport")
                        .onPreferenceChange(CoverFramePreference.self) { tileFrames = $0 }
                        .task(id: model.phase) {
                            followedID = nil
                            guard model.phase == .running else { return }
                            // 合并密集的进度事件，每 0.7 秒最多移动一次；结束或离开界面即取消。
                            while !Task.isCancelled {
                                if let target = followTarget, target != followedID {
                                    followedID = target
                                    let frame = tileFrames[target]
                                    let isVisible = frame.map {
                                        $0.minY >= 12 && $0.maxY <= viewport.size.height - 12
                                    } ?? false
                                    if !isVisible {
                                        withAnimation(.easeInOut(duration: 0.35)) {
                                            proxy.scrollTo(target, anchor: .center)
                                        }
                                    }
                                }
                                do { try await Task.sleep(for: .milliseconds(700)) }
                                catch { return }
                            }
                        }
                        .onChange(of: filter) { followedID = nil }
                        .onChange(of: model.stage) { followedID = nil }
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.025),
                                                     .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                    }
                }
            }
        }
    }

    // MARK: 头部：文件夹名 + 统计 + 筛选

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.inputURL?.lastPathComponent ?? "")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(model.tracks.count) 首")
                    Text("·")
                    Text(model.totalSize.byteString)
                    if model.losslessCount > 0 {
                        Text("·")
                        Text("\(model.losslessCount) 首无损")
                    }
                    if model.phase == .scanning {
                        ProgressView().controlSize(.mini).padding(.leading, 4)
                        Text("正在识别…")
                    } else if model.needsLoginCount > 0 {
                        Label("\(model.needsLoginCount) 首需要 QQ音乐登录", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.gold)
                            .padding(.leading, 6)
                            .help("musicex 格式的文件密钥不在文件里，需要本机登录过 QQ音乐")
                    }
                }
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            filterBar
        }
    }

    private var filterBar: some View {
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
                    .padding(.vertical, 5)
                    .background {
                        if filter == f {
                            Capsule().fill(Theme.chipSelected)
                                .shadow(color: Theme.shadow.opacity(0.5), radius: 2, y: 1)
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
    }

    private var emptyFolder: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.grid.3x3")
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
}

// MARK: - 一张封面

struct CoverTile: View {
    @Environment(AppModel.self) private var model
    let track: Track
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                CoverArt(track: track)
                stateOverlay
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.coverEdge, lineWidth: 0.6))
            .overlay(alignment: .bottomTrailing) { badge.padding(7) }
            .shadow(color: Theme.coverShadow, radius: hover ? 14 : 8, y: hover ? 8 : 4)
            .scaleEffect(hover ? 1.025 : 1)
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(track.status.isFailure ? Theme.danger : Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { h in
            guard !DebugHooks.snapshotting else { return }   // 调试截图不受鼠标位置影响
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { hover = h }
        }
        .help(helpText)
        .onTapGesture(count: 2) { model.reveal(track) }
        .contextMenu {
            Button("在 Finder 中显示") { model.reveal(track) }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(track.outputPath ?? track.path, forType: .string)
            }
        }
        .animation(.easeOut(duration: 0.25), value: track.status)
        .animation(.easeOut(duration: 0.35), value: track.coverPath)
    }

    /// 未处理的封面保持灰色；解密成功即恢复彩色，等待转码时也不再变灰。
    private var dimmed: Bool {
        track.status == .pending
    }

    private var subtitle: String {
        if case .failed(let msg) = track.status { return msg }
        let artist = track.displayArtist.isEmpty ? "未知歌手" : track.displayArtist
        return artist
    }

    private var helpText: String {
        var parts = [track.displayTitle]
        if !track.displayArtist.isEmpty { parts.append(track.displayArtist) }
        if let album = track.album, !album.isEmpty { parts.append(album + (track.year.map { " · \($0)" } ?? "")) }
        parts.append("\(track.displayFormat) · \(track.kindLabel) · \(track.size.byteString)")
        if case .failed(let msg) = track.status { parts.append("失败：\(msg)") }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch track.status {
        case .decrypting, .transcoding:
            ZStack {
                Color.black.opacity(0.48)
                VStack(spacing: 8) {
                    EqualizerBars(count: 5, active: true, color: AnyShapeStyle(Color.white), barWidth: 3.5, spacing: 3)
                        .frame(width: 34, height: 26)
                    Text(track.status == .decrypting ? "解密中" : "转码中")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .transition(.opacity)
        case .failed:
            Theme.danger.opacity(0.28).transition(.opacity)
        default:
            if hover {
                // 悬停：底部露出格式和大小
                VStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Text(track.displayFormat)
                        Spacer(minLength: 4)
                        Text(track.size.byteString)
                    }
                    .lineLimit(1)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch track.status {
        case .decrypted:
            StatusDot(symbol: "checkmark", color: Theme.success)
                .help(model.outputMode == .lossless ? "解密完成" : "解密完成，等待转码")
        case .done:
            StatusDot(symbol: "checkmark", color: Theme.success)
        case .skipped:
            StatusDot(symbol: "checkmark", color: Theme.textSecondary)
                .help("输出目录里已经有了，已跳过")
        case .failed:
            StatusDot(symbol: "xmark", color: Theme.danger)
        default:
            if track.needsLogin && model.phase != .running {
                StatusDot(symbol: "key.fill", color: Theme.gold)
                    .help("需要 QQ音乐登录态才能取到密钥")
            }
        }
    }
}

/// 封面右下角的小圆标
private struct StatusDot: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 21, height: 21)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - 封面图（没有封面时画一张「生成的唱片封面」）

struct CoverArt: View {
    let track: Track

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            if let path = track.coverPath, let image = CoverCache.image(path, side: 360) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .transition(.opacity)
            } else {
                placeholder(side)
            }
        }
    }

    private func placeholder(_ side: CGFloat) -> some View {
        let c1 = Color(hue: track.hue, saturation: 0.42, brightness: 0.92)
        let c2 = Color(hue: (track.hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.48)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
            // 唱片纹
            Circle()
                .strokeBorder(.white.opacity(0.13), lineWidth: side * 0.11)
                .frame(width: side * 0.9, height: side * 0.9)
                .offset(x: side * 0.38, y: -side * 0.42)
            Circle()
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                .frame(width: side * 0.5, height: side * 0.5)
                .offset(x: side * 0.58, y: -side * 0.62)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.system(size: side * 0.12, weight: .heavy))
                    .tracking(-0.3)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(track.displayArtist)
                    .font(.system(size: side * 0.075, weight: .medium))
                    .opacity(0.8)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(side * 0.09)
        }
        .frame(width: side, height: side)
    }
}

/// 封面缩略图缓存（同一张专辑多首歌共用，不重复解码 800×800 的 JPEG）
enum CoverCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ path: String, side: CGFloat = 96) -> NSImage? {
        let key = "\(Int(side))|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let full = NSImage(contentsOfFile: path) else { return nil }
        let thumb = NSImage(size: NSSize(width: side, height: side))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        thumb.unlockFocus()
        cache.setObject(thumb, forKey: key)
        return thumb
    }

    /// 背景用：事先虚化好的封面（比实时 blur 平滑，也不吃 GPU）
    static func blurred(_ path: String) -> NSImage? {
        let key = "blur|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let side: CGFloat = 240
        let scale = side / max(source.extent.width, 1)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            .cropped(to: small.extent)
        guard let cg = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: small.extent) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: side, height: side))
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct SkeletonTile: View {
    @State private var shimmer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.overlay(0.07))
                .aspectRatio(1, contentMode: .fit)
            RoundedRectangle(cornerRadius: 4).fill(Theme.overlay(0.07)).frame(width: 90, height: 10)
            RoundedRectangle(cornerRadius: 4).fill(Theme.overlay(0.05)).frame(width: 60, height: 8)
        }
        .opacity(shimmer ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(), value: shimmer)
        .onAppear { shimmer = true }
    }
}

// MARK: - 背景：当前这首的封面放大、虚化

struct CoverBackdrop: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    /// 背景用哪张封面：每个文件夹定一次就不再变。
    /// （跟着「正在处理的那首」换，并行转码时一秒换好几次，整个窗口一直闪）
    @State private var pinned: String?

    private var firstCover: String? {
        model.tracks.first(where: { $0.coverPath != nil })?.coverPath
    }

    var body: some View {
        ZStack {
            Theme.ink
            if let path = pinned, let image = CoverCache.blurred(path) {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(scheme == .dark ? 0.6 : 0.45)
                        .clipped()
                }
                .id(path)
                .transition(.opacity)
            }
            // 压一层底色，保证文字对比
            Theme.ink.opacity(scheme == .dark ? 0.55 : 0.6)
        }
        .animation(.easeInOut(duration: 1.2), value: pinned)
        .onChange(of: model.inputURL) { pinned = nil }
        .onChange(of: firstCover, initial: true) { _, cover in
            if pinned == nil { pinned = cover }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 滚动条

/// 封面墙的滚动条：强制用 macOS 的「浮动」样式 —— 细、半透明、滚动时才出现，
/// 鼠标移上去会变粗、可以拖。系统设置里「显示滚动条：始终」或接着鼠标时，
/// 默认会变成带灰色轨道的老式滚动条，夹在封面和侧栏之间很难看。
private struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.apply() }

    final class ProbeView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // 用户改系统设置或插拔鼠标时，AppKit 会把样式改回去，再设一次
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.findScrollView() else { return }
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
                scroll.hasHorizontalScroller = false
                scroll.verticalScroller?.controlSize = .small
                scroll.scrollerInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 2)
            }
        }

        /// SwiftUI 的 ScrollView 底下是一个 NSScrollView：从自己往上找
        private func findScrollView() -> NSScrollView? {
            if let s = enclosingScrollView { return s }
            var view = superview
            while let v = view {
                if let s = v as? NSScrollView { return s }
                view = v.superview
            }
            return nil
        }
    }
}

/// 只测量已布局的封面；未布局的目标由 ScrollViewReader 定位。
private struct CoverFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
