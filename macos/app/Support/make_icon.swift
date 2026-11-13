// 画 App 图标（1024×1024 PNG）：深色圆角底 + 极光光晕 + 渐变音柱。
//   swift Support/make_icon.swift out.png
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

let cyan = (0.42, 0.86, 0.93)
let violet = (0.62, 0.48, 1.00)
let rose = (1.00, 0.47, 0.62)

// macOS 图标网格：824 的圆角方块居中，留出阴影空间
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = rect.width * 0.225
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0, 0, 0, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(color(0.035, 0.039, 0.067))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// 底色渐变
let base = CGGradient(colorsSpace: cs, colors: [color(0.07, 0.07, 0.13), color(0.02, 0.02, 0.05)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// 极光光斑
func glow(_ c: (Double, Double, Double), _ center: CGPoint, _ r: CGFloat, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: cs,
                       colors: [color(c.0, c.1, c.2, a), color(c.0, c.1, c.2, 0)] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
}
glow(violet, CGPoint(x: 300, y: 760), 520, 0.75)
glow(cyan, CGPoint(x: 820, y: 640), 420, 0.45)
glow(rose, CGPoint(x: 640, y: 180), 460, 0.55)

// 顶部高光
let sheen = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.14), color(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY + 60), options: [])

// 音柱
let heights: [CGFloat] = [0.30, 0.52, 0.74, 0.48, 0.62]
let barW: CGFloat = 70
let gap: CGFloat = 38
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (size - totalW) / 2
let maxH: CGFloat = 520
let midY = size / 2

let barGradient = CGGradient(colorsSpace: cs,
                             colors: [color(cyan.0, cyan.1, cyan.2), color(violet.0, violet.1, violet.2),
                                      color(rose.0, rose.1, rose.2)] as CFArray,
                             locations: [0, 0.5, 1])!
let bars = CGMutablePath()
for h in heights {
    let bh = maxH * h
    let r = CGRect(x: x, y: midY - bh / 2, width: barW, height: bh)
    bars.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    x += barW + gap
}

// 柱子辉光
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: color(violet.0, violet.1, violet.2, 0.9))
ctx.addPath(bars)
ctx.setFillColor(color(1, 1, 1, 0.9))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bars)
ctx.clip()
ctx.drawLinearGradient(barGradient, start: CGPoint(x: rect.minX + 120, y: rect.maxY - 120),
                       end: CGPoint(x: rect.maxX - 120, y: rect.minY + 120), options: [])
// 柱子上半部提亮
let barSheen = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.55), color(1, 1, 1, 0)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(barSheen, start: CGPoint(x: 0, y: midY + maxH / 2), end: CGPoint(x: 0, y: midY), options: [])
ctx.restoreGState()

ctx.restoreGState()

// 细描边
ctx.addPath(squircle)
ctx.setStrokeColor(color(1, 1, 1, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("icon → \(out)")
