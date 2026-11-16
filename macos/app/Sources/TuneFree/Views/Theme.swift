import AppKit
import SwiftUI

/// 跟随外观变化的颜色：深色模式用 dark（就是原来那套），浅色模式用 light
func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

enum Theme {
    /// 全界面共用的连续圆角，与系统版本无关。
    static let cornerRadius: CGFloat = 12
    static var roundedShape: InterfaceRoundedRectangle { InterfaceRoundedRectangle() }

    // 底色
    static let inkNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(0.035, 0.039, 0.067) : rgb(0.982, 0.982, 0.987)
    }
    static let ink = Color(nsColor: inkNS)

    // 品牌色：浅色模式下稍微压暗，白底上对比够
    static let accent = adaptive(light: rgb(0.10, 0.60, 0.76), dark: rgb(0.42, 0.86, 0.93))     // 青
    static let accent2 = adaptive(light: rgb(0.47, 0.32, 0.96), dark: rgb(0.62, 0.48, 1.00))    // 紫
    static let accent3 = adaptive(light: rgb(0.93, 0.30, 0.50), dark: rgb(1.00, 0.47, 0.62))    // 玫红
    static let gold = adaptive(light: rgb(0.78, 0.50, 0.06), dark: rgb(0.98, 0.80, 0.47))
    static let success = adaptive(light: rgb(0.09, 0.60, 0.35), dark: rgb(0.36, 0.89, 0.62))
    static let danger = adaptive(light: rgb(0.86, 0.20, 0.27), dark: rgb(1.00, 0.42, 0.45))

    // 文字
    static let textPrimary = adaptive(light: rgb(0.07, 0.07, 0.12, 0.92), dark: NSColor(white: 1, alpha: 0.95))
    static let textSecondary = adaptive(light: rgb(0.07, 0.07, 0.12, 0.62), dark: NSColor(white: 1, alpha: 0.62))
    static let textTertiary = adaptive(light: rgb(0.07, 0.07, 0.12, 0.42), dark: NSColor(white: 1, alpha: 0.38))
    static let hairline = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))

    /// 半透明叠加（悬停、浅底、描边）：深色模式是白色，浅色模式是淡黑色
    static func overlay(_ alpha: Double) -> Color {
        adaptive(light: NSColor(white: 0, alpha: alpha * 0.55), dark: NSColor(white: 1, alpha: alpha))
    }

    /// 凹槽底色（分段选择器、筛选胶囊的轨道）
    static let well = adaptive(light: NSColor(white: 0, alpha: 0.055), dark: NSColor(white: 0, alpha: 0.25))

    /// 「停止」按钮（白字）：深色模式是半透明白，浅色模式是深灰，保证白字看得清
    static let stopTop = adaptive(light: rgb(0.40, 0.40, 0.48), dark: NSColor(white: 1, alpha: 0.14))
    static let stopBottom = adaptive(light: rgb(0.30, 0.30, 0.38), dark: NSColor(white: 1, alpha: 0.08))

    /// 卡片阴影
    static let shadow = adaptive(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 0, alpha: 0.35))

    /// 玻璃卡片的高光描边
    static let glassEdgeTop = adaptive(light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.18))
    static let glassEdgeBottom = adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))

    // 封面墙
    /// 侧栏底色：比背景实一点，不用毛玻璃（虚化封面背景上毛玻璃会发灰）
    static let panel = adaptive(light: rgb(0.949, 0.935, 0.985), dark: rgb(0.10, 0.095, 0.14))
    static let panelEdge = adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.07))
    /// 分段选择器里选中的那一格
    static let chipSelected = adaptive(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 1, alpha: 0.16))
    static let coverEdge = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.1))
    static let coverShadow = adaptive(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 0, alpha: 0.45))
    static let stopFill = adaptive(light: rgb(0.32, 0.32, 0.38), dark: NSColor(white: 1, alpha: 0.16))
    static let ringGradient = AngularGradient(colors: [accent2, accent3, accent2], center: .center)

    static let brand = LinearGradient(colors: [accent, accent2, accent3],
                                      startPoint: .leading, endPoint: .trailing)
    static let brandDiagonal = LinearGradient(colors: [accent, accent2, accent3],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 小控件的半径最多为短边的四分之一，保留直边，避免变成胶囊或圆形。
/// 填充、裁切和描边共用轮廓；描边内缩时同步减小半径。
struct InterfaceRoundedRectangle: InsettableShape {
    private var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = min(Theme.cornerRadius, min(rect.width, rect.height) * 0.25)
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        return RoundedRectangle(cornerRadius: max(0, radius - insetAmount), style: .continuous)
            .path(in: bounds)
    }

    func inset(by amount: CGFloat) -> Self {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

// MARK: - 玻璃卡片

struct GlassCard: ViewModifier {
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                Theme.roundedShape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Theme.roundedShape
                            .fill(Theme.overlay(0.025))
                    )
            }
            .overlay {
                Theme.roundedShape
                    .strokeBorder(
                        LinearGradient(colors: [Theme.glassEdgeTop, Theme.overlay(0.04), Theme.glassEdgeBottom],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            }
            .shadow(color: Theme.shadow, radius: 30, y: 18)
    }
}

extension View {
    func glass(padding: CGFloat = 0) -> some View {
        modifier(GlassCard(padding: padding))
    }
}

// MARK: - 按钮

struct PrimaryButtonStyle: ButtonStyle {
    var tint: LinearGradient = Theme.brandDiagonal
    var height: CGFloat = 46
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background {
                ZStack {
                    Theme.roundedShape.fill(tint)
                    Theme.roundedShape
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .clear],
                                             startPoint: .top, endPoint: .center))
                }
            }
            .overlay(Theme.roundedShape
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.8))
            .shadow(color: Theme.accent2.opacity(enabled ? 0.45 : 0), radius: 18, y: 8)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: height)
            .background(Theme.roundedShape
                .fill(Theme.overlay(configuration.isPressed ? 0.16 : (hover ? 0.11 : 0.07))))
            .overlay(Theme.roundedShape
                .strokeBorder(Theme.overlay(0.1), lineWidth: 0.8))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct IconButtonStyle: ButtonStyle {
    var active = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            .frame(width: 32, height: 28)
            .background(Theme.roundedShape
                .fill(Theme.overlay(active ? 0.12 : (hover ? 0.08 : 0))))
            .onHover { hover = $0 }
    }
}

// MARK: - 小部件

struct StatusPill: View {
    let ok: Bool
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Theme.success : Theme.gold)
                .frame(width: 6, height: 6)
                .shadow(color: (ok ? Theme.success : Theme.gold).opacity(0.8), radius: 4)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.roundedShape.fill(Theme.overlay(0.06)))
        .overlay(Theme.roundedShape.strokeBorder(Theme.overlay(0.08), lineWidth: 0.8))
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.textSecondary
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Theme.roundedShape.fill(color.opacity(0.14)))
            .overlay(Theme.roundedShape.strokeBorder(color.opacity(0.28), lineWidth: 0.6))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// 细进度条（更新窗口用）
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
            }
        }
    }
}
