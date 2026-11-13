import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            AuroraBackground(energy: model.phase == .running ? 1 : 0)
                .animation(.easeInOut(duration: 1.2), value: model.phase == .running)

            VStack(spacing: 0) {
                TopBar()
                    .frame(height: 52)

                if model.needsFullDiskAccess && !model.fullDiskAccessBannerDismissed && model.phase != .running {
                    DiskAccessBanner()
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

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
        .preferredColorScheme(model.appearance.colorScheme)
        .frame(minWidth: 1000, minHeight: 660)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)   // 动画由 .animation(value: phase) 负责
        } isTargeted: { dropTargeted = $0 }
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: model.phase)
        .sheet(item: Binding(get: { model.sheet }, set: { if $0 == nil { model.dismissSheet() } else { model.sheet = $0 } })) { kind in
            Group {
                switch kind {
                case .onboarding: OnboardingView(firstRun: true)
                case .about: OnboardingView(firstRun: false)
                case .update: UpdateView()
                }
            }
            .environment(model)
            .environment(updater)
        }
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

                // 进度条常驻、用透明度切换：if/else 里带 transition 的写法在任务很快结束时
                // 会卡在过渡中途（进度条不消失、结果卡片不出现）
                let running = model.phase == .running
                ProgressDock()
                    .opacity(running ? 1 : 0)
                    .offset(y: running ? 0 : 24)
                    .allowsHitTesting(running)
                    .accessibilityHidden(!running)
                    .padding(14)
                    .animation(.spring(response: 0.45, dampingFraction: 0.9), value: running)

                if model.phase == .finished {
                    SummaryView()
                        .padding(14)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater

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

            if let release = updater.badge {
                Button { model.sheet = .update } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("新版本 \(release.version)")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.brandDiagonal))
                    .shadow(color: Theme.accent2.opacity(0.5), radius: 8)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("有新版本可以下载")
                .transition(.scale.combined(with: .opacity))
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

/// QQ音乐是 App Store 版、TuneFree 又没有完全磁盘访问权限时的提示条
struct DiskAccessBanner: View {
    @Environment(AppModel.self) private var model
    @State private var openedSettings = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.gold)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.gold.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("请给 TuneFree 打开「完全磁盘访问权限」")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(openedSettings
                     ? "在列表里打开 TuneFree 的开关；没有 TuneFree 就点「+」，从「应用程序」里选 TuneFree。开好后回到这里会自动检查。"
                     : "你的 QQ音乐是 App Store 版，歌曲和登录信息在它的沙盒里。没有这个权限，新版格式的歌会解密失败。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("重新检查") { model.refreshDiskAccess() }
                .buttonStyle(GhostButtonStyle(height: 32))
            Button {
                AppModel.openFullDiskAccessSettings()
                openedSettings = true
            } label: {
                Label("打开系统设置", systemImage: "gearshape")
            }
            .buttonStyle(PrimaryButtonStyle(tint: LinearGradient(colors: [Theme.gold, Theme.accent3],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                            height: 32))
            .frame(width: 140)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { model.fullDiskAccessBannerDismissed = true }
            } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .help("不再提示（权限状态变化后会再提示）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.gold.opacity(0.08)))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.gold.opacity(0.35), lineWidth: 1))
    }
}
