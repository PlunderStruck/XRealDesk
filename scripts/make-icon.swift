// Renders Resources/AppIcon.icns: three curved panels floating in front of a dark gradient.
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1), NSColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)])!
        .draw(in: bg, angle: -90)
    // Three panels on an arc: side panels smaller and angled.
    let accent = NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1)
    func panel(_ rect: NSRect, _ alpha: CGFloat, skew: CGFloat) {
        let p = NSBezierPath()
        let inset = rect.height * 0.08 * skew
        p.move(to: NSPoint(x: rect.minX, y: rect.minY + (skew > 0 ? inset : 0)))
        p.line(to: NSPoint(x: rect.maxX, y: rect.minY + (skew < 0 ? -inset : 0)))
        p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - (skew < 0 ? -inset : 0)))
        p.line(to: NSPoint(x: rect.minX, y: rect.maxY - (skew > 0 ? inset : 0)))
        p.close()
        NSGradient(colors: [accent.withAlphaComponent(alpha), NSColor(red: 0.55, green: 0.35, blue: 1.0, alpha: alpha)])!
            .draw(in: p, angle: 60)
    }
    panel(NSRect(x: 170 * s, y: 420 * s, width: 190 * s, height: 190 * s), 0.55, skew: 1)
    panel(NSRect(x: 664 * s, y: 420 * s, width: 190 * s, height: 190 * s), 0.55, skew: -1)
    let center = NSBezierPath(roundedRect: NSRect(x: 380 * s, y: 395 * s, width: 264 * s, height: 240 * s), xRadius: 14 * s, yRadius: 14 * s)
    NSGradient(colors: [accent, NSColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 1)])!.draw(in: center, angle: 60)
    // Glasses silhouette.
    if let sym = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 250 * s, weight: .semibold)) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let w = 400 * s, h = w * sym.size.height / sym.size.width
        tinted.draw(in: NSRect(x: 512 * s - w / 2, y: 170 * s, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon_\(name).png"))
}
