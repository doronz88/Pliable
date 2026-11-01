// Renders Resources/AppIcon.icns: a rounded-square icon showing a small key/value tree.
// Usage: swift Tools/make-icon.swift   (run from the repo root)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt body centered in 1024 with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.33, green: 0.36, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.10, green: 0.62, blue: 0.86, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // subtle top highlight
    let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

    // Tree rows: (indent level, disclosure: 0 none / 1 open / 2 closed, key width, value width)
    let rows: [(Int, Int, CGFloat, CGFloat)] = [(0, 1, 250, 0), (1, 0, 150, 200), (1, 2, 190, 130), (1, 0, 120, 170)]
    let rowH: CGFloat = 92, gap: CGFloat = 46
    let total = CGFloat(rows.count) * rowH + CGFloat(rows.count - 1) * gap
    var y = 512 + total / 2 - rowH
    for (level, disc, kw, vw) in rows {
        let x0: CGFloat = 232 + CGFloat(level) * 96
        let midY = y + rowH / 2
        if disc != 0 {
            let t = CGMutablePath()
            if disc == 1 { // open: pointing down
                t.move(to: CGPoint(x: x0, y: midY + 20)); t.addLine(to: CGPoint(x: x0 + 48, y: midY + 20)); t.addLine(to: CGPoint(x: x0 + 24, y: midY - 22))
            } else { // closed: pointing right
                t.move(to: CGPoint(x: x0 + 6, y: midY + 24)); t.addLine(to: CGPoint(x: x0 + 6, y: midY - 24)); t.addLine(to: CGPoint(x: x0 + 46, y: midY))
            }
            t.closeSubpath()
            ctx.addPath(t); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        }
        let kx = x0 + 70
        let key = CGPath(roundedRect: CGRect(x: kx, y: y + 14, width: kw, height: rowH - 28), cornerWidth: 32, cornerHeight: 32, transform: nil)
        ctx.addPath(key); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        if vw > 0 {
            let val = CGPath(roundedRect: CGRect(x: 622, y: y + 14, width: vw, height: rowH - 28), cornerWidth: 32, cornerHeight: 32, transform: nil)
            ctx.addPath(val); ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor); ctx.fillPath()
        }
        y -= rowH + gap
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
