// Renders the DMG window background at 1x and 2x. Usage: make-dmg-background.swift <out-dir>
// Geometry must match scripts/dmg-settings.py (640x436 content, icons centered at x 170 and 470, y 170 from the top).
// Finder draws icon labels in black over background images, so the design stays light.
import AppKit

let width: CGFloat = 640, height: CGFloat = 436
// Space kept clear at the bottom for when Finder hides its tab bar.
let spare: CGFloat = 36
let iconY: CGFloat = height - 170
let appX: CGFloat = 170, linkX: CGFloat = 470
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let navy = rgb(0x0B2F66), blue = rgb(0x2F6FE0), lime = rgb(0x9BD11C), slate = rgb(0x52627C)

func glow(at p: NSPoint, radius: CGFloat, color: NSColor) {
    NSGradient(colors: [color, color.withAlphaComponent(0)])!
        .draw(fromCenter: p, radius: 0, toCenter: p, radius: radius, options: [])
}

func draw() {
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [rgb(0xF7FAFF), rgb(0xDDE8F8)])!.draw(in: bounds, angle: -90)

    glow(at: NSPoint(x: appX - 20, y: iconY + 30), radius: 230, color: blue.withAlphaComponent(0.22))
    glow(at: NSPoint(x: linkX + 30, y: iconY - 20), radius: 230, color: lime.withAlphaComponent(0.26))

    // Dot grid that fades toward the edges
    for gx in stride(from: CGFloat(12), to: width, by: 20) {
        for gy in stride(from: CGFloat(12), to: height, by: 20) {
            let d = hypot((gx - width / 2) / width, (gy - iconY) / height)
            navy.withAlphaComponent(max(0, 0.16 - d * 0.2)).setFill()
            NSBezierPath(ovalIn: NSRect(x: gx - 0.9, y: gy - 0.9, width: 1.8, height: 1.8)).fill()
        }
    }

    // Frosted slots the icons and their labels sit in
    for x in [appX, linkX] {
        let rect = NSRect(x: x - 80, y: iconY - 98, width: 160, height: 176)
        let slot = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = navy.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.white.withAlphaComponent(0.62).setFill(); slot.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke(); slot.lineWidth = 1; slot.stroke()
    }

    // Arcing dotted arrow from the app to Applications
    let start = NSPoint(x: appX + 96, y: iconY + 8), end = NSPoint(x: linkX - 98, y: iconY + 8)
    let c1 = NSPoint(x: start.x + 30, y: iconY + 46), c2 = NSPoint(x: end.x - 30, y: iconY + 46)
    let arc = NSBezierPath()
    arc.move(to: start)
    arc.curve(to: end, controlPoint1: c1, controlPoint2: c2)
    arc.lineWidth = 4
    arc.lineCapStyle = .round
    arc.setLineDash([0.1, 10], count: 2, phase: 0)
    blue.setStroke(); arc.stroke()
    // Arrowhead aligned with the curve's final tangent
    let angle = atan2(end.y - c2.y, end.x - c2.x)
    func wing(_ offset: CGFloat) -> NSPoint {
        NSPoint(x: end.x - 14 * cos(angle + offset), y: end.y - 14 * sin(angle + offset))
    }
    let head = NSBezierPath()
    head.move(to: wing(0.6))
    head.line(to: end)
    head.line(to: wing(-0.6))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Fallback for Gatekeeper on unsigned builds
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let label: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: slate, .paragraphStyle: center,
    ]
    let code: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: navy, .paragraphStyle: center,
    ]
    let command = NSAttributedString(string: "xattr -dr com.apple.quarantine /Applications/Explorer.app", attributes: code)
    let pillWidth = command.size().width + 36
    let pill = NSBezierPath(roundedRect: NSRect(x: (width - pillWidth) / 2, y: spare + 52, width: pillWidth, height: 28), xRadius: 14, yRadius: 14)
    NSColor.white.withAlphaComponent(0.8).setFill(); pill.fill()
    navy.withAlphaComponent(0.1).setStroke(); pill.lineWidth = 1; pill.stroke()
    NSAttributedString(string: "If macOS won't open it, run this in Terminal", attributes: label)
        .draw(in: NSRect(x: 0, y: spare + 86, width: width, height: 16))
    command.draw(in: NSRect(x: 0, y: spare + 58, width: width, height: 16))
}

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
