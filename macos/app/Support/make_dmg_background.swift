// DMG 窗口背景：720×440 pt，输出 1x 与 2x 两张 PNG（build.sh 再合成多分辨率 TIFF）。
//   swift Support/make_dmg_background.swift <输出目录> <图标 1024px PNG>
//
// 窗口布局（与 build.sh 里的 dmgbuild 设置一致）：
//   TuneFree 图标中心 (190, 215)，「应用程序」中心 (530, 215)，图标 112 pt。
// 背景用浅色：Finder 的图标文字在浅色模式下是黑色，浅底最清楚。
import AppKit
import CoreGraphics

let W: CGFloat = 720, H: CGFloat = 440
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconPath = CommandLine.arguments[2]
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let violet = NSColor(srgbRed: 0.62, green: 0.48, blue: 1.00, alpha: 1)
let cyan = NSColor(srgbRed: 0.30, green: 0.78, blue: 0.90, alpha: 1)
let rose = NSColor(srgbRed: 1.00, green: 0.47, blue: 0.62, alpha: 1)
let ink = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 1)
let inkSoft = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 0.56)

let iconImage = NSImage(contentsOfFile: iconPath)!

func render(scale: CGFloat, to name: String) {
    let pw = Int(W * scale), ph = Int(H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)          // 让 2x 图带上 144 dpi，Finder 才会按 Retina 显示
    NSGraphicsContext.saveGraphicsState()
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ns
    let cg = ns.cgContext
    // 左上原点
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)

    // 底色：很浅的暖白 → 淡紫
    let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 0.985, green: 0.982, blue: 0.995, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.950, green: 0.940, blue: 0.985, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    cg.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: H), options: [])

    func glow(_ c: NSColor, _ p: CGPoint, _ r: CGFloat, _ a: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [c.withAlphaComponent(a).cgColor, c.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
        cg.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
    }
    glow(violet, CGPoint(x: 90, y: 40), 360, 0.20)
    glow(cyan, CGPoint(x: 700, y: 120), 300, 0.16)
    glow(rose, CGPoint(x: 520, y: 470), 320, 0.16)

    // 文字
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, x: CGFloat, y: CGFloat,
              align: CGFloat = 0.5, kern: CGFloat = 0) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern])
        let sz = attr.size()
        cg.saveGState()
        cg.translateBy(x: x - sz.width * align, y: y + sz.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        attr.draw(at: .zero)
        cg.restoreGState()
    }

    // 顶部品牌：小图标 + 标题
    let iconSize: CGFloat = 34
    let titleAttr = NSAttributedString(string: "TuneFree for Mac",
                                       attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold)])
    let titleW = titleAttr.size().width
    let groupW = iconSize + 10 + titleW
    let gx = W / 2 - groupW / 2
    // 图标 PNG 四周有阴影留白（824/1024 是主体）
    let full = iconSize / 824 * 1024
    let iconRect = CGRect(x: gx + iconSize / 2 - full / 2, y: 46 - full / 2, width: full, height: full)
    cg.saveGState()
    cg.translateBy(x: 0, y: iconRect.minY * 2 + iconRect.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    iconImage.draw(in: iconRect)
    cg.restoreGState()
    text("TuneFree for Mac", size: 22, weight: .bold, color: ink, x: gx + iconSize + 10, y: 32, align: 0)
    text("把 QQ音乐下载的加密歌曲，变成任何播放器都能放的 MP3 / FLAC", size: 13, weight: .regular,
         color: inkSoft, x: W / 2, y: 74)

    // 中间：从 TuneFree 指向「应用程序」的渐变箭头 + 提示
    let ay: CGFloat = 207
    let x0: CGFloat = 268, x1: CGFloat = 446
    cg.saveGState()
    let shaft = CGMutablePath()
    shaft.move(to: CGPoint(x: x0, y: ay))
    shaft.addCurve(to: CGPoint(x: x1, y: ay), control1: CGPoint(x: x0 + 55, y: ay - 26),
                   control2: CGPoint(x: x1 - 55, y: ay - 26))
    cg.addPath(shaft)
    cg.setLineWidth(5)
    cg.setLineCap(.round)
    cg.replacePathWithStrokedPath()
    // 箭头尖
    let tip = CGMutablePath()
    tip.move(to: CGPoint(x: x1 + 14, y: ay + 1))
    tip.addLine(to: CGPoint(x: x1 - 6, y: ay - 13))
    tip.addLine(to: CGPoint(x: x1 - 2, y: ay + 1))
    tip.addLine(to: CGPoint(x: x1 - 8, y: ay + 14))
    tip.closeSubpath()
    cg.addPath(tip)
    cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [cyan.cgColor, violet.cgColor, rose.cgColor] as CFArray, locations: [0, 0.5, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1 + 14, y: 0), options: [])
    cg.restoreGState()
    text("拖到「应用程序」即可安装", size: 13, weight: .semibold, color: ink.withAlphaComponent(0.78),
         x: (x0 + x1) / 2, y: ay + 18)

    // 底部：第一次打开的提示卡片
    let card = CGRect(x: 70, y: 340, width: W - 140, height: 66)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 16, cornerHeight: 16, transform: nil)
    cg.addPath(cardPath)
    cg.setFillColor(NSColor.white.withAlphaComponent(0.72).cgColor)
    cg.fillPath()
    cg.addPath(cardPath)
    cg.setStrokeColor(violet.withAlphaComponent(0.22).cgColor)
    cg.setLineWidth(1)
    cg.strokePath()
    let badge = CGRect(x: card.minX + 18, y: card.midY - 15, width: 30, height: 30)
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: badge, cornerWidth: 9, cornerHeight: 9, transform: nil))
    cg.clip()
    cg.drawLinearGradient(grad, start: CGPoint(x: badge.minX, y: badge.minY), end: CGPoint(x: badge.maxX, y: badge.maxY), options: [])
    cg.restoreGState()
    text("1", size: 15, weight: .bold, color: .white, x: badge.midX, y: badge.minY + 5)
    text("第一次打开：在「应用程序」里右键 TuneFree → 打开 → 打开", size: 13, weight: .semibold, color: ink,
         x: badge.maxX + 12, y: card.minY + 14, align: 0)
    text("App 未经 Apple 公证，首次需要这样确认一次；仍打不开：系统设置 → 隐私与安全性 →「仍要打开」",
         size: 10.5, weight: .regular, color: inkSoft, x: badge.maxX + 12, y: card.minY + 36, align: 0)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("·", name, pw, "×", ph)
}

render(scale: 1, to: "background.png")
render(scale: 2, to: "background@2x.png")
