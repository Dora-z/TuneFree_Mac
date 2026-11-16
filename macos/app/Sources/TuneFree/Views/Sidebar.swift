import SwiftUI

/// 封面墙右侧的侧栏：上面是导出设置，下面是进度 / 结果 / 主按钮
struct WallSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                settings
                ScrollView { settings }.scrollIndicators(.never)
            }

            Spacer(minLength: 12)
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 18)

            RunPanel()
                .padding(18)
        }
        .frame(maxHeight: .infinity)
        .card()
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.outputMode)
    }

    private var settings: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 22) {
                section("导出到") {
                    Button { model.chooseOutput() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.outputURL.lastPathComponent)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(abbreviate(model.outputURL.path))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Text("更改")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.accent2)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(Theme.roundedShape.fill(Theme.well))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                }

                section("格式") {
                    FormatPicker(selection: $model.outputMode)
                        .disabled(model.isBusy)
                    if model.outputMode != .lossless {
                        HStack(spacing: 10) {
                            Text("MP3 音质")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                            PillPicker(options: [128, 192, 320], selection: $model.bitrate) { "\($0)k" }
                        }
                        .padding(.top, 4)
                        .disabled(model.isBusy)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showAdvanced.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            SectionLabel(text: "选项")
                            Spacer()
                            if !showAdvanced {
                                Text(optionsSummary)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                                .rotationEffect(.degrees(showAdvanced ? 0 : -90))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        VStack(spacing: 0) {
                            ToggleRow(title: "联网补全标签", detail: "向 QQ音乐查询封面、专辑、歌词", isOn: $model.onlineTags)
                            ToggleRow(title: "文件名补标签", detail: "从「歌手-歌名」回填", isOn: $model.fillTags)
                            ToggleRow(title: "另存歌词文件", detail: ".lrc，车机 / 播放器同步显示", isOn: $model.writeLrc)
                            ToggleRow(title: "容器校验", detail: "逐页 CRC，确保无损坏", isOn: $model.verify)
                            ToggleRow(title: "覆盖已有文件", detail: "默认跳过已转好的歌曲", isOn: $model.force)
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("并行转码").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                    Text("同时处理的歌曲数").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                Stepper(value: $model.jobs, in: 1...AppModel.maxJobs) {
                                    Text("\(model.jobs)")
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.textPrimary)
                                }
                                .fixedSize()
                            }
                            .padding(.vertical, 6)
                        }
                        .disabled(model.isBusy)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(18)
    }

    private var optionsSummary: String {
        var parts: [String] = []
        if model.onlineTags { parts.append("补全标签") }
        if model.writeLrc { parts.append(".lrc") }
        if model.force { parts.append("覆盖") }
        parts.append("并行 \(model.jobs)")
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: title)
            content()
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - 进度 / 结果 / 主按钮

private struct RunPanel: View {
    @Environment(AppModel.self) private var model
    @State private var showIssues = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ring.frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    detail
                }
                Spacer(minLength: 0)
            }

            if model.phase == .finished, let s = model.summary {
                HStack(spacing: 0) {
                    metric("\(s.succeeded)", "成功", Theme.success)
                    metric("\(s.failed)", "失败", s.failed > 0 ? Theme.danger : Theme.textTertiary)
                    metric(duration(s.elapsed), "用时", Theme.textPrimary)
                }
                .padding(.vertical, 8)
                .background(Theme.roundedShape.fill(Theme.well))
            }

            buttons
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: model.phase)
    }

    // 圆环：就绪时显示曲目数，运行时显示百分比，完成时打勾
    @ViewBuilder
    private var ring: some View {
        let finished = model.phase == .finished
        let summary = model.summary
        let ok = (summary?.failed ?? 0) == 0 && (summary?.errors.isEmpty ?? true) && !(summary?.cancelled ?? false)
        ZStack {
            Circle().stroke(Theme.overlay(0.09), lineWidth: 6)
            Circle()
                .trim(from: 0, to: finished ? 1 : max(0.001, model.overallProgress))
                .stroke(finished ? AnyShapeStyle(ok ? Theme.success : Theme.gold) : AnyShapeStyle(Theme.ringGradient),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(model.phase == .running || finished ? 1 : 0)
            Group {
                switch model.phase {
                case .running:
                    Text("\(Int((model.overallProgress * 100).rounded()))%")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                case .finished:
                    Image(systemName: summary?.cancelled == true ? "pause.fill" : (ok ? "checkmark" : "exclamationmark"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(ok ? Theme.success : Theme.gold)
                default:
                    VStack(spacing: 0) {
                        Text("\(model.tracks.count)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("首").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: model.overallProgress)
    }

    private var headline: String {
        switch model.phase {
        case .scanning: return "正在识别…"
        case .running: return model.cancelling ? "正在停止" : "正在\(model.stage)"
        case .finished:
            guard let s = model.summary else { return "完成" }
            if s.cancelled { return "已停止" }
            if s.found == 0 { return "没有可处理的文件" }
            if s.failed == 0 && s.errors.isEmpty { return model.retrying ? "重试完成" : "全部完成" }
            if s.succeeded == 0 { return "没有成功的歌曲" }
            return "有 \(s.failed) 首没成功"
        default:
            return model.tracks.isEmpty ? "没有歌曲" : "准备就绪"
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.phase {
            case .running:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(model.stageDone) / \(model.stageTotal)").monospacedDigit()
                        if let start = model.startedAt {
                            TimelineView(.periodic(from: start, by: 1)) { ctx in
                                Text("· " + clock(ctx.date.timeIntervalSince(start))).monospacedDigit()
                            }
                        }
                    }
                    Text(model.activeFileName.isEmpty ? "准备中…" : model.activeFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Theme.textTertiary)
                }
            case .finished:
                let tagged = model.onlineTaggedCount
                Text(tagged > 0 ? "\(tagged) 首补全了封面 / 歌词" : "导出到 \(model.outputURL.lastPathComponent)")
                    .lineLimit(2)
            default:
                Text("\(model.outputMode.title)\(model.outputMode == .lossless ? "" : " · \(model.bitrate)k")")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.phase {
        case .running:
            Button(role: .cancel) { model.cancel() } label: {
                Label(model.cancelling ? "正在停止…" : "停止", systemImage: "stop.fill")
            }
            .buttonStyle(SolidButtonStyle(fill: Theme.stopFill))
            .disabled(model.cancelling)
            .keyboardShortcut(".", modifiers: .command)
        case .finished:
            VStack(spacing: 8) {
                if model.failedCount > 0 {
                    Button { model.retryFailed() } label: {
                        Label("仅重试失败项（\(model.failedCount)）", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SolidButtonStyle())
                    .help("重新生成失败歌曲的输出，其他歌曲保持不变")
                }
                if let s = model.summary, !s.errors.isEmpty {
                    Button { showIssues = true } label: {
                        Label("查看原因与解决办法（\(s.errors.count)）", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(GhostButtonStyle(height: 32))
                    .popover(isPresented: $showIssues, arrowEdge: .top) { IssuesList(summary: s) }
                }
                Button { model.revealOutput() } label: {
                    Label("在 Finder 中打开", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(SolidButtonStyle())
                HStack(spacing: 8) {
                    Button("再转一次") { model.start() }
                        .buttonStyle(GhostButtonStyle(height: 32))
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("新的一批") { model.reset() }
                        .buttonStyle(GhostButtonStyle(height: 32))

                }
                .frame(maxWidth: .infinity)
            }
        default:
            VStack(spacing: 8) {
                Button { model.start() } label: {
                    Label("开始转换", systemImage: "play.fill")
                }
                .buttonStyle(SolidButtonStyle())
                .disabled(model.tracks.isEmpty || model.phase == .scanning || model.phase == .idle)
                .keyboardShortcut(.return, modifiers: .command)
                Text("⌘↩ 开始 · 本地解密，不上传歌曲")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func clock(_ s: Double) -> String {
        let s = Int(max(0, s))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func duration(_ s: Double) -> String {
        s < 60 ? String(format: "%.0f 秒", s) : String(format: "%d 分 %02d", Int(s) / 60, Int(s) % 60)
    }
}

/// 结果里的问题列表（弹出框）
private struct IssuesList: View {
    let summary: RunSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(summary.errors.count) 条问题")
                    .font(.system(size: 13, weight: .semibold))
                Text("密钥问题：打开并登录 QQ音乐后重试。权限问题：在设置中检查目录访问权限，或更换导出位置。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(Array(summary.errors.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.path.isEmpty ? "后端" : URL(fileURLWithPath: e.path).lastPathComponent)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("\(stageName(e.stage)) · \(hint(e.reason, e.message))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private func stageName(_ stage: String) -> String {
        switch stage {
        case "decrypt": return "解密"
        case "transcode": return "转码"
        case "verify": return "校验"
        default: return stage
        }
    }

    private func hint(_ reason: String, _ message: String) -> String {
        switch reason {
        case "ekey": return "取不到密钥：请在这台 Mac 上打开并登录一次 QQ音乐后重试。（\(message)）"
        case "empty": return "文件是空的，可能还没下载完"
        case "io": return "读不了文件：检查权限或外置磁盘是否挂载"
        case "write": return "写不进输出目录：换一个位置试试"
        default: return message
        }
    }
}

// MARK: - 小部件

/// 三种输出格式并排
private struct FormatPicker: View {
    @Binding var selection: OutputMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OutputMode.allCases) { mode in
                let on = selection == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = mode }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 14, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Theme.accent2 : Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(Theme.roundedShape
                        .fill(on ? Theme.accent2.opacity(0.12) : Theme.well))
                    .overlay(Theme.roundedShape
                        .strokeBorder(on ? Theme.accent2.opacity(0.55) : .clear, lineWidth: 1.2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.subtitle)
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent2)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .padding(.vertical, 6)
    }
}

struct PillPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { opt in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = opt }
                } label: {
                    Text(label(opt))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == opt ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if selection == opt {
                                Theme.roundedShape
                                    .fill(Theme.chipSelected)
                                    .shadow(color: Theme.shadow.opacity(0.5), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.roundedShape.fill(Theme.well))
    }
}

/// 实心主按钮（不再用三色渐变）
struct SolidButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent2
    var height: CGFloat = 40
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Theme.roundedShape.fill(fill))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private extension View {
    /// 侧栏的卡片底
    func card() -> some View {
        self
            .background(Theme.roundedShape.fill(Theme.panel))
            .overlay(Theme.roundedShape.strokeBorder(Theme.panelEdge, lineWidth: 0.8))
            .shadow(color: Theme.shadow.opacity(0.5), radius: 16, y: 8)
    }
}
