// Renders the Explorer app icon (folder + tree glyph on a gradient squircle) into an .iconset directory.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.80, alpha: 1)])!.draw(in: path, angle: -90)
    // Tree lines
    NSColor.white.withAlphaComponent(0.85).setStroke()
    let tree = NSBezierPath()
    tree.lineWidth = s * 0.03
    tree.lineCapStyle = .round
    let x0 = rect.minX + rect.width * 0.24
    tree.move(to: NSPoint(x: x0, y: rect.maxY - rect.height * 0.26))
    tree.line(to: NSPoint(x: x0, y: rect.minY + rect.height * 0.28))
    for f in [0.62, 0.28] {
        let y = rect.minY + rect.height * f
        tree.move(to: NSPoint(x: x0, y: y)); tree.line(to: NSPoint(x: x0 + rect.width * 0.14, y: y))
    }
    tree.stroke()
    // Folders
    func folder(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
        let h = w * 0.72
        let tab = NSBezierPath(roundedRect: NSRect(x: x, y: y + h * 0.78, width: w * 0.42, height: h * 0.3), xRadius: w * 0.06, yRadius: w * 0.06)
        NSColor(calibratedRed: 1, green: 0.84, blue: 0.40, alpha: 1).setFill(); tab.fill()
        let body = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h * 0.9), xRadius: w * 0.08, yRadius: w * 0.08)
        NSColor(calibratedRed: 1, green: 0.78, blue: 0.25, alpha: 1).setFill(); body.fill()
    }
    folder(rect.minX + rect.width * 0.14, rect.maxY - rect.height * 0.30, rect.width * 0.22)
    folder(x0 + rect.width * 0.17, rect.minY + rect.height * 0.53, rect.width * 0.48)
    folder(x0 + rect.width * 0.17, rect.minY + rect.height * 0.19, rect.width * 0.48)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
