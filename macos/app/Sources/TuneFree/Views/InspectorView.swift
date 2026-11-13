import SwiftUI

/// 右侧设置面板
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdvanced = true

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 输出位置
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "导出到")
                        Button { model.chooseOutput() } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "externaldrive.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.12)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.outputURL.lastPathComponent)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(abbreviate(model.outputURL.path))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                    }

                    // 格式
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "输出格式")
                        VStack(spacing: 6) {
                            ForEach(OutputMode.allCases) { mode in
                                ModeCard(mode: mode, selected: model.outputMode == mode) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.outputMode = mode }
                                }
                            }
                        }
                    }
                    .disabled(model.isBusy)

                    // 码率
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel(text: "MP3 音质")
                            Spacer()
                            Text(bitrateHint)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        PillPicker(options: [128, 192, 320], selection: $model.bitrate) { "\($0)k" }
                    }
                    .opacity(model.outputMode == .lossless ? 0.35 : 1)
                    .disabled(model.outputMode == .lossless || model.isBusy)

                    // 高级
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showAdvanced.toggle() }
                        } label: {
                            HStack {
                                SectionLabel(text: "高级")
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .rotationEffect(.degrees(showAdvanced ? 0 : -90))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showAdvanced {
                            VStack(spacing: 2) {
                                ToggleRow(symbol: "checkmark.seal", title: "容器校验", detail: "逐页 CRC，确保无损坏", isOn: $model.verify)
                                ToggleRow(symbol: "photo.on.rectangle.angled", title: "联网补全标签", detail: "封面、专辑、年份、歌词", isOn: $model.onlineTags)
                                ToggleRow(symbol: "tag", title: "文件名补标签", detail: "从「歌手-歌名」回填", isOn: $model.fillTags)
                                ToggleRow(symbol: "text.quote", title: "另存歌词文件", detail: ".lrc，车机 / 播放器同步显示", isOn: $model.writeLrc)
                                ToggleRow(symbol: "arrow.clockwise", title: "覆盖已有文件", detail: "默认跳过已转好的歌曲", isOn: $model.force)
                                HStack(spacing: 10) {
                                    rowIcon("cpu")
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("并行转码").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                        Text("同时处理的歌曲数").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer()
                                    Stepper(value: $model.jobs, in: 1...8) {
                                        Text("\(model.jobs)")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.textPrimary)
                                    }
                                    .fixedSize()
                                }
                                .padding(.vertical, 8)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .disabled(model.isBusy)
                }
                .padding(20)
            }
            .scrollIndicators(.never)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            actionArea
                .padding(20)
        }
        .glass(radius: 24)
    }

    @ViewBuilder
    private var actionArea: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .running:
                Button(role: .cancel) { model.cancel() } label: {
                    Label(model.cancelling ? "正在停止…" : "停止", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.08)],
                                                                    startPoint: .top, endPoint: .bottom)))
                .disabled(model.cancelling)
                .keyboardShortcut(".", modifiers: .command)
            default:
                Button { model.start() } label: {
                    Label(model.phase == .finished ? "再次转换" : "开始转换", systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.tracks.isEmpty || model.phase == .scanning || model.phase == .idle)
                .keyboardShortcut(.return, modifiers: .command)
            }
            Text(footnote)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var footnote: String {
        switch model.phase {
        case .idle: return "先选择一个文件夹"
        case .running: return "停止后，当前这首会处理完再退出"
        default:
            if model.tracks.isEmpty { return "没有可处理的歌曲" }
            return "⌘↩ 开始 · 全程本地处理，不联网上传"
        }
    }

    private var bitrateHint: String {
        switch model.bitrate {
        case 320: return "推荐 · 接近无损听感"
        case 192: return "平衡"
        default: return "体积最小"
        }
    }

    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct ModeCard: View {
    let mode: OutputMode
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.textSecondary))
                    .frame(width: 30, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? AnyShapeStyle(Theme.brandDiagonal) : AnyShapeStyle(Color.white.opacity(0.06)))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(mode.subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                ZStack {
                    Circle().strokeBorder(selected ? Theme.accent : Theme.textTertiary, lineWidth: 1.4)
                    if selected { Circle().fill(Theme.accent).padding(3.5) }
                }
                .frame(width: 15, height: 15)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.08 : (hover ? 0.04 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.14) : .clear, lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent2)
                .labelsHidden()
        }
        .padding(.vertical, 4)
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
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == opt ? Color.white : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background {
                            if selection == opt {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Theme.brandDiagonal)
                                    .shadow(color: Theme.accent2.opacity(0.4), radius: 8, y: 3)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.8))
    }
}
