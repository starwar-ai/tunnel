// 生成 IntranetTunnel 应用图标: swift make-icon.swift <输出.iconset目录>
// 绘制蓝紫渐变圆角方块 + 白色 ⇅ 箭头（与菜单栏图标呼应），输出全部 10 个标准尺寸 PNG
import AppKit

func drawArrowsFallback(in size: CGFloat) {
    // 备用手绘 ⇅：左箭头向上、右箭头向下
    let w = size * 0.075
    let len = size * 0.46
    let head = size * 0.16
    let x1 = size * 0.36, x2 = size * 0.64
    let cy = size * 0.5
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let shaft = NSBezierPath()
    shaft.lineWidth = w
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: x1, y: cy - len / 2))
    shaft.line(to: NSPoint(x: x1, y: cy + len / 2 - head / 2))
    shaft.stroke()
    let up = NSBezierPath()
    up.move(to: NSPoint(x: x1, y: cy + len / 2 + head * 0.10))
    up.line(to: NSPoint(x: x1 - head / 2, y: cy + len / 2 - head * 0.55))
    up.line(to: NSPoint(x: x1 + head / 2, y: cy + len / 2 - head * 0.55))
    up.close()
    up.fill()
    let shaft2 = NSBezierPath()
    shaft2.lineWidth = w
    shaft2.lineCapStyle = .round
    shaft2.move(to: NSPoint(x: x2, y: cy + len / 2))
    shaft2.line(to: NSPoint(x: x2, y: cy - len / 2 + head / 2))
    shaft2.stroke()
    let down = NSBezierPath()
    down.move(to: NSPoint(x: x2, y: cy - len / 2 - head * 0.10))
    down.line(to: NSPoint(x: x2 - head / 2, y: cy - len / 2 + head * 0.55))
    down.line(to: NSPoint(x: x2 + head / 2, y: cy - len / 2 + head * 0.55))
    down.close()
    down.fill()
}

func renderIcon(px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let radius = px * 0.2245
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    bg.addClip()
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.49, blue: 0.97, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.95, alpha: 1),
    ])
    grad?.draw(in: bg, angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.54, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        let r = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        let dr = NSRect(x: (px - symbol.size.width) / 2,
                        y: (px - symbol.size.height) / 2,
                        width: symbol.size.width, height: symbol.size.height)
        tinted.draw(in: dr)
    } else {
        drawArrowsFallback(in: px)
    }
    img.unlockFocus()
    return img
}

func savePNG(_ img: NSImage, to url: URL) throws {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败: \(url.lastPathComponent)"])
    }
    try png.write(to: url)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// (逻辑尺寸, 实际像素) — iconutil 要求的完整 iconset
let specs: [(String, CGFloat, CGFloat)] = [
    ("icon_16x16.png", 16, 16), ("icon_16x16@2x.png", 16, 32),
    ("icon_32x32.png", 32, 32), ("icon_32x32@2x.png", 32, 64),
    ("icon_128x128.png", 128, 128), ("icon_128x128@2x.png", 128, 256),
    ("icon_256x256.png", 256, 256), ("icon_256x256@2x.png", 256, 512),
    ("icon_512x512.png", 512, 512), ("icon_512x512@2x.png", 512, 1024),
]

do {
    for (name, _, px) in specs {
        try savePNG(renderIcon(px: px), to: outDir.appendingPathComponent(name))
    }
    print("✓ 图标已生成: \(outDir.path)")
} catch {
    FileHandle.standardError.write("图标生成失败: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
