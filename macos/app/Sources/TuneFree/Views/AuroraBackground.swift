import SwiftUI

/// 底色 + 缓慢流动的极光光斑。运行时光斑会更亮、流得更快一点。
/// 深色模式：深底 + 暗角；浅色模式：近白底 + 淡彩光斑，边缘带一点淡紫。
struct AuroraBackground: View {
    var energy: Double = 0   // 0…1
    @Environment(\.colorScheme) private var scheme

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            Theme.ink
            blobs
            GeometryReader { geo in
                RadialGradient(colors: [.clear, isDark ? Color.black.opacity(0.55) : Theme.accent2.opacity(0.07)],
                               center: .center,
                               startRadius: min(geo.size.width, geo.size.height) * 0.3,
                               endRadius: max(geo.size.width, geo.size.height) * 0.85)
            }
            NoiseOverlay().opacity(isDark ? 0.045 : 0.03).blendMode(.overlay)
        }
        .ignoresSafeArea()
    }

    private var blobs: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * (0.05 + 0.07 * energy)
            let k = isDark ? 1.0 : 0.5      // 浅色模式光斑淡一半，保持通透
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(Theme.accent2, size: max(w, h) * 0.75,
                         x: w * (0.18 + 0.10 * sin(t * 1.1)), y: h * (0.15 + 0.12 * cos(t * 0.9)),
                         opacity: (0.40 + 0.15 * energy) * k)
                    blob(Theme.accent, size: max(w, h) * 0.6,
                         x: w * (0.85 + 0.08 * cos(t * 0.8)), y: h * (0.25 + 0.15 * sin(t * 1.3)),
                         opacity: (0.26 + 0.14 * energy) * k)
                    blob(Theme.accent3, size: max(w, h) * 0.55,
                         x: w * (0.60 + 0.15 * sin(t * 0.7 + 1)), y: h * (1.0 + 0.08 * cos(t * 1.2)),
                         opacity: (0.24 + 0.12 * energy) * k)
                    blob(Color(red: 0.15, green: 0.30, blue: 0.95), size: max(w, h) * 0.5,
                         x: w * (0.05 + 0.06 * cos(t)), y: h * (0.95 + 0.05 * sin(t * 1.4)),
                         opacity: 0.30 * k)
                }
                .drawingGroup()
            }
        }
    }

    private func blob(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .position(x: x, y: y)
            .blur(radius: 40)
    }
}

private struct NoiseOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRNG(seed: 0x5EED)
            let step: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    if Int.random(in: 0..<3, using: &rng) == 0 {
                        let v = Double.random(in: 0...1, using: &rng)
                        ctx.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                                 with: .color(.white.opacity(v)))
                    }
                    x += step
                }
                y += step
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// 跳动的音频柱，用在空状态和运行中
struct EqualizerBars: View {
    var count = 5
    var active = true
    var color: AnyShapeStyle = AnyShapeStyle(Theme.brand)
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        let phase = Double(i) * 1.7
                        let v = active ? 0.35 + 0.65 * abs(sin(t * (2.2 + Double(i) * 0.37) + phase)) : 0.25
                        Capsule()
                            .fill(color)
                            .frame(width: barWidth, height: max(barWidth, geo.size.height * v))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}
