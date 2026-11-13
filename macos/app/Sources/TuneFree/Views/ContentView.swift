import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            AuroraBackground(energy: model.phase == .running ? 1 : 0)
                .animation(.easeInOut(duration: 1.2), value: model.phase == .running)

            VStack(spacing: 0) {
                TopBar()
                    .frame(height: 52)

                HStack(alignment: .top, spacing: 18) {
                    mainArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if model.phase != .idle {
                        InspectorView()
                            .frame(width: 300)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .ignoresSafeArea(.container, edges: .top)

            if model.showLog {
                VStack {
                    Spacer()
                    LogConsole()
                        .frame(height: 260)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1000, minHeight: 660)
        .dropDestination(for: URL.self) { urls, _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { model.handleDrop(urls) }
        } isTargeted: { dropTargeted = $0 }
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: model.phase)
        .alert("出错了", isPresented: .init(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("好") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    @ViewBuilder
    private var mainArea: some View {
        if model.phase == .idle {
            EmptyStateView(isTargeted: dropTargeted)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            ZStack(alignment: .bottom) {
                LibraryView()
                    .padding(.top, 8)
                    .glass(radius: 24)
                    .overlay {
                        if dropTargeted && !model.isBusy {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(Theme.brandDiagonal, lineWidth: 2)
                                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.accent2.opacity(0.08)))
                                .overlay(Label("松手换成这个文件夹", systemImage: "arrow.down.circle.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary))
                        }
                    }

                Group {
                    if model.phase == .running {
                        ProgressDock()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if model.phase == .finished {
                        SummaryView()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(14)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            // 给红绿灯留位置
            Color.clear.frame(width: 62)

            HStack(spacing: 9) {
                LogoMark().frame(width: 22, height: 22)
                Text("TuneFree")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.textPrimary)
                Text("for Mac")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            }

            Spacer()

            HStack(spacing: 8) {
                StatusPill(ok: true, label: "离线解密")
                StatusPill(ok: model.hasFFmpeg, label: model.hasFFmpeg ? "转码引擎就绪" : "缺少 ffmpeg")
                StatusPill(ok: model.hasQQLogin, label: model.hasQQLogin ? "已检测到 QQ音乐登录态" : "未检测到 QQ音乐登录态")
                    .help("新版 QQ音乐下载的 musicex 文件需要本机登录态来取密钥；QTag/V1 格式不需要")
            }

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.showLog.toggle() }
            } label: {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(IconButtonStyle(active: model.showLog))
            .help("运行日志（⌘L）")
            .keyboardShortcut("l", modifiers: .command)
        }
        .padding(.horizontal, 16)
    }
}

/// 品牌标：渐变圆角方块里的三根音柱
struct LogoMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.28, style: .continuous)
                    .fill(Theme.brandDiagonal)
                HStack(spacing: s * 0.09) {
                    ForEach([0.38, 0.62, 0.46], id: \.self) { h in
                        Capsule().fill(.white).frame(width: s * 0.11, height: s * h)
                    }
                }
            }
            .shadow(color: Theme.accent2.opacity(0.6), radius: s * 0.3)
        }
    }
}
