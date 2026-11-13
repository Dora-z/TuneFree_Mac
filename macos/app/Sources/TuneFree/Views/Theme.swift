import SwiftUI

enum Theme {
    static let ink = Color(red: 0.035, green: 0.039, blue: 0.067)
    static let accent = Color(red: 0.42, green: 0.86, blue: 0.93)       // 青
    static let accent2 = Color(red: 0.62, green: 0.48, blue: 1.00)      // 紫
    static let accent3 = Color(red: 1.00, green: 0.47, blue: 0.62)      // 玫红
    static let gold = Color(red: 0.98, green: 0.80, blue: 0.47)
    static let success = Color(red: 0.36, green: 0.89, blue: 0.62)
    static let danger = Color(red: 1.00, green: 0.42, blue: 0.45)

    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.08)

    static let brand = LinearGradient(colors: [accent, accent2, accent3],
                                      startPoint: .leading, endPoint: .trailing)
    static let brandDiagonal = LinearGradient(colors: [accent, accent2, accent3],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - 玻璃卡片

struct GlassCard: ViewModifier {
    var radius: CGFloat = 22
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.white.opacity(0.025))
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04), .white.opacity(0.08)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
    }
}

extension View {
    func glass(radius: CGFloat = 22, padding: CGFloat = 0) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
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
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .clear],
                                             startPoint: .top, endPoint: .center))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
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
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.16 : (hover ? 0.11 : 0.07))))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.8))
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
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(active ? 0.12 : (hover ? 0.08 : 0))))
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
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
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
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(color.opacity(0.28), lineWidth: 0.6))
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
