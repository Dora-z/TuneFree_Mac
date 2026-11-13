import SwiftUI

/// 完成后的结果卡片
struct SummaryView: View {
    @Environment(AppModel.self) private var model
    @State private var appear = false
    @State private var showErrors = false

    var body: some View {
        let s = model.summary ?? RunSummary()
        let allGood = !s.cancelled && s.failed == 0 && s.errors.isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(allGood ? AnyShapeStyle(LinearGradient(colors: [Theme.success, Theme.accent],
                                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                                      : AnyShapeStyle(LinearGradient(colors: [Theme.gold, Theme.accent3],
                                                                       startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .frame(width: 54, height: 54)
                        .shadow(color: (allGood ? Theme.success : Theme.gold).opacity(0.5), radius: 16)
                    Image(systemName: s.cancelled ? "pause.fill" : (allGood ? "checkmark" : "exclamationmark"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .scaleEffect(appear ? 1 : 0.3)
                        .symbolEffect(.bounce, value: appear)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(s, allGood))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle(s))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { model.revealOutput() } label: {
                    Label("在 Finder 中打开", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(PrimaryButtonStyle(height: 38))
                .frame(width: 170)
                Button { model.reset() } label: {
                    Text("新的一批")
                }
                .buttonStyle(GhostButtonStyle(height: 38))
            }

            HStack(spacing: 10) {
                metric("\(s.decrypted + s.decryptSkipped)", "解密成功", Theme.accent)
                metric("\(s.mp3OK + s.mp3Skipped)", model.outputMode == .lossless ? "已输出" : "MP3 就绪", Theme.accent2)
                metric("\(s.failed)", "失败", s.failed > 0 ? Theme.danger : Theme.textTertiary)
                metric(String(format: "%.1fs", s.elapsed), "用时", Theme.gold)
            }
            .padding(.top, 18)

            if !s.errors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showErrors.toggle() }
                    } label: {
                        HStack {
                            Label("\(s.errors.count) 条问题", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.gold)
                            Spacer()
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showErrors ? 0 : -90))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showErrors {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(s.errors.enumerated()), id: \.offset) { _, e in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.path.isEmpty ? "后端" : URL(fileURLWithPath: e.path).lastPathComponent)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text("\(stageName(e.stage)) · \(hint(e.reason, e.message))")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textSecondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 130)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.gold.opacity(0.06)))
                .padding(.top, 14)
            }
        }
        .padding(22)
        .glass(radius: 24)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) { appear = true }
        }
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.overlay(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.overlay(0.06), lineWidth: 0.8))
    }

    private func title(_ s: RunSummary, _ ok: Bool) -> String {
        if s.cancelled { return "已停止" }
        if s.found == 0 { return "没有可处理的文件" }
        if ok { return "全部完成" }
        if s.succeeded == 0 { return "没有成功的歌曲" }
        return "完成，但有 \(s.failed) 首没成功"
    }

    private func subtitle(_ s: RunSummary) -> String {
        if s.cancelled { return "已处理的歌曲保留在输出目录，下次会自动跳过" }
        let tagged = model.onlineTaggedCount
        let tagNote = tagged > 0 ? " · \(tagged) 首补全了封面 / 歌词" : ""
        return "共 \(s.found) 首\(tagNote) · 导出到 \(model.outputURL.lastPathComponent)"
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
