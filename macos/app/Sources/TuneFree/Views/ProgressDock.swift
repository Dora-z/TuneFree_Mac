import SwiftUI

/// 运行中浮在列表底部的进度条
struct ProgressDock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            ProgressRing(progress: model.overallProgress)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.cancelling ? "正在停止" : "正在\(model.stage)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(model.stageDone) / \(model.stageTotal)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                    Spacer()
                    if let start = model.startedAt, model.phase == .running {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text(elapsed(ctx.date.timeIntervalSince(start)))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                GlowBar(progress: model.overallProgress, active: model.phase == .running)
                    .frame(height: 6)
                Text(model.activeFileName.isEmpty ? "准备中…" : model.activeFileName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .glass(radius: 22)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: model.overallProgress)
    }

    private func elapsed(_ s: Double) -> String {
        let s = Int(max(0, s))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Theme.overlay(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(AngularGradient(colors: [Theme.accent, Theme.accent2, Theme.accent3, Theme.accent],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.accent2.opacity(0.6), radius: 6)
            Text("\(Int((progress * 100).rounded()))")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
        }
    }
}

struct GlowBar: View {
    let progress: Double
    var active = true
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.overlay(0.08))
                Capsule()
                    .fill(Theme.brand)
                    .frame(width: max(6, geo.size.width * progress))
                    .shadow(color: Theme.accent2.opacity(0.8), radius: 8)
                    .overlay(alignment: .trailing) {
                        TimelineView(.animation(minimumInterval: nil, paused: !active)) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            Circle()
                                .fill(.white)
                                .frame(width: 6, height: 6)
                                .blur(radius: 2)
                                .opacity(0.6 + 0.4 * sin(t * 4))
                        }
                    }
            }
        }
    }
}
