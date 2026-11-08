// render-icons.swift — 渲染 anyFS 图标 (CoreGraphics, 无设计工具依赖)
// 用法: swiftc -O -o /tmp/render-icons render-icons.swift && /tmp/render-icons <输出目录>
// 产物: menubar.png / menubar@2x.png (模板图) + AppIcon.iconset/*.png
import Cocoa

// MARK: - 绘制
// 设计: SSD 圆角矩形轮廓 + 内部双向箭头 (读⇄写 数据桥)
// 全部用笔画, 单色 (菜单栏模板图只看 alpha; App 图标用白色画在深色底上)
func drawGlyph(_ ctx: CGContext, _ S: CGFloat, color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // SSD 轮廓
    let lw = S * 0.098
    ctx.setLineWidth(lw)
    let inset = S * 0.13
    let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let radius = S * 0.20
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()

    // 双向箭头: 上 → (读), 下 ← (写)
    let alw = S * 0.084
    ctx.setLineWidth(alw)
    let cy1 = S * 0.605, cy2 = S * 0.395
    let x1 = S * 0.30, x2 = S * 0.70
    let ah = S * 0.085
    // 上箭头 (向右)
    ctx.move(to: CGPoint(x: x1, y: cy1))
    ctx.addLine(to: CGPoint(x: x2 - ah * 0.3, y: cy1))
    ctx.move(to: CGPoint(x: x2 - ah, y: cy1 + ah * 0.9))
    ctx.addLine(to: CGPoint(x: x2, y: cy1))
    ctx.addLine(to: CGPoint(x: x2 - ah, y: cy1 - ah * 0.9))
    // 下箭头 (向左)
    ctx.move(to: CGPoint(x: x2, y: cy2))
    ctx.addLine(to: CGPoint(x: x1 + ah * 0.3, y: cy2))
    ctx.move(to: CGPoint(x: x1 + ah, y: cy2 + ah * 0.9))
    ctx.addLine(to: CGPoint(x: x1, y: cy2))
    ctx.addLine(to: CGPoint(x: x1 + ah, y: cy2 - ah * 0.9))
    ctx.strokePath()
}

func makeContext(_ size: Int) -> CGContext? {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

func savePNG(_ ctx: CGContext, _ path: String) {
    guard let img = ctx.makeImage(),
          let rep = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    else { print("FAIL: \(path)"); return }
    try? rep.write(to: URL(fileURLWithPath: path))
}

// MARK: - 菜单栏模板图 (黑 glyph, 透明底, 系统按深浅模式自动着色)
func renderMenuBar(_ dir: String) {
    for (px, name) in [(18, "menubar.png"), (36, "menubar@2x.png")] {
        let ctx = makeContext(px)!
        // 高清先画大再缩放, 18px 也清晰
        let big = makeContext(px * 8)!
        drawGlyph(big, CGFloat(px * 8), color: NSColor.black.cgColor)
        ctx.interpolationQuality = .high
        ctx.draw(big.makeImage()!, in: CGRect(x: 0, y: 0, width: px, height: px))
        savePNG(ctx, "\(dir)/\(name)")
    }
    print("menubar icons done")
}

// MARK: - App 图标 (深色圆角方块 + 白 glyph)
func renderAppIcon(_ dir: String) {
    let setDir = "\(dir)/AppIcon.iconset"
    try? FileManager.default.createDirectory(atPath: setDir, withIntermediateDirectories: true)
    let sizes: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for (name, px) in sizes {
        let S = CGFloat(px)
        let ctx = makeContext(px)!
        // 深色圆角底 (macOS 圆角比例 ~22.37%)
        let bg = CGRect(x: 0, y: 0, width: S, height: S)
        let r = S * 0.2237
        let bgPath = CGPath(roundedRect: bg, cornerWidth: r, cornerHeight: r, transform: nil)
        // 纵向微渐变 (#2A2A2E → #17171A)
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(calibratedRed: 0.165, green: 0.165, blue: 0.18, alpha: 1).cgColor,
                                       NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: S/2, y: S), end: CGPoint(x: S/2, y: 0), options: [])
        ctx.restoreGState()
        // glyph 缩到 72% 居中
        let g = S * 0.72
        let off = (S - g) / 2
        ctx.saveGState()
        ctx.translateBy(x: off, y: off)
        ctx.scaleBy(x: g / 1000, y: g / 1000)
        drawGlyph(ctx, 1000, color: NSColor.white.cgColor)
        ctx.restoreGState()
        savePNG(ctx, "\(setDir)/\(name)")
    }
    print("app iconset done")
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
renderMenuBar(dir)
renderAppIcon(dir)
