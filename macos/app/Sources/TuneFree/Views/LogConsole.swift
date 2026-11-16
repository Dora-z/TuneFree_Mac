import SwiftUI

struct LogConsole: View {
    @Environment(AppModel.self) private var model
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal").foregroundStyle(Theme.accent)
                Text("运行日志").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("\(model.logs.count)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                Spacer()
                Button {
                    let text = model.logs.map { "\(Self.timeFormat.string(from: $0.date)) [\($0.level)] \($0.message)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle())
                    .help("拷贝全部日志")
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.showLog = false }
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.logs.isEmpty {
                            Text("开始转换后，这里会显示每一步的细节。")
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.top, 8)
                        }
                        ForEach(model.logs) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Self.timeFormat.string(from: line.date)).foregroundStyle(Theme.textTertiary)
                                Text(line.message)
                                    .foregroundStyle(color(line.level))
                                    .textSelection(.enabled)
                            }
                            .id(line.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .onChange(of: model.logs.count) {
                    if let last = model.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Theme.roundedShape.fill(Color.black.opacity(0.55)))
        .background(Theme.roundedShape.fill(.ultraThinMaterial))
        .overlay(Theme.roundedShape.strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .environment(\.colorScheme, .dark)     // 日志面板始终是深色终端风格
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return Theme.danger
        case "warning": return Theme.gold
        case "debug": return Theme.textTertiary
        default: return Theme.textSecondary
        }
    }
}
