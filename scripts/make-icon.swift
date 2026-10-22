// Draws the Mission Plus app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

/// The icon at 1024×1024, following macOS's icon grid (an 824pt rounded square, centred).
func drawIcon(in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep blue to indigo, like a Mission Control desktop at dusk.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.20, green: 0.42, blue: 0.95, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.27, green: 0.18, blue: 0.62, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Soft glass highlight across the top.
    let sheen = [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray
    let sheenGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: sheen, locations: [0, 1])!
    ctx.drawLinearGradient(sheenGradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 60), options: [])

    // Two windows behind, one in front: the Mission Control spread.
    card(ctx, CGRect(x: 170, y: 520, width: 330, height: 230), alpha: 0.55)
    card(ctx, CGRect(x: 524, y: 520, width: 330, height: 230), alpha: 0.55)
    let front = CGRect(x: 250, y: 215, width: 524, height: 360)
    card(ctx, front, alpha: 0.95)

    // The traffic lights on the front window, big enough to read at small sizes.
    let d: CGFloat = 70
    let y = front.maxY - 34 - d
    light(ctx, CGRect(x: front.minX + 36, y: y, width: d, height: d),
          NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1))   // #FF5F57
    light(ctx, CGRect(x: front.minX + 36 + d + 26, y: y, width: d, height: d),
          NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)) // #FEBC2E
    ctx.restoreGState()

    // Hairline rim, so the tile holds its edge on light and dark backgrounds.
    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func card(_ ctx: CGContext, _ rect: CGRect, alpha: CGFloat) {
    let path = CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor(white: 0, alpha: 0.30).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}

func light(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor) {
    ctx.addEllipse(in: rect)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
    ctx.addEllipse(in: rect.insetBy(dx: 1.5, dy: 1.5))
    ctx.setStrokeColor(color.blended(withFraction: 0.25, of: .black)!.withAlphaComponent(0.6).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: root.appendingPathComponent("docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns and docs/icon.png")
