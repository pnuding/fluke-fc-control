// Renders the app icon: a yellow meter body with a dark display showing a reading and a wireless glyph.
// Usage: swift Tools/make_icon.swift <out-dir>   (then see build notes in README for the iconset step)
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no bitmap context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext

// Body: yellow, lit from the top left.
let margin: CGFloat = 20
let body = NSRect(x: margin, y: margin, width: CGFloat(size) - 2 * margin, height: CGFloat(size) - 2 * margin)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 215, yRadius: 215)
NSGradient(colors: [color(0xFFDF4A), color(0xFFC800), color(0xE6A100)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: bodyPath, angle: -60)
cg.saveGState()
bodyPath.addClip()
NSGradient(colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(fromCenter: NSPoint(x: 260, y: 880), radius: 0, toCenter: NSPoint(x: 260, y: 880), radius: 600, options: [])
cg.restoreGState()

// Display.
let display = NSRect(x: 150, y: 330, width: 724, height: 430)
let displayPath = NSBezierPath(roundedRect: display, xRadius: 70, yRadius: 70)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35).cgColor)
color(0x14171C).setFill()
displayPath.fill()
cg.restoreGState()
NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: displayPath, angle: -90)
color(0xFFFFFF, 0.14).setStroke()
displayPath.lineWidth = 3
displayPath.stroke()

// Reading.
let font = NSFont.monospacedSystemFont(ofSize: 250, weight: .semibold)
let text = NSAttributedString(string: "5.06", attributes: [.font: font, .foregroundColor: color(0xF4F6F8)])
let textSize = text.size()
text.draw(at: NSPoint(x: display.midX - textSize.width / 2 - 10, y: display.midY - textSize.height / 2 - 20))

// Wireless glyph, top right of the display.
if let image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 96, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color(0xFFC800)]))) {
    let s = image.size
    image.draw(in: NSRect(x: display.maxX - s.width - 52, y: display.maxY - s.height - 40, width: s.width, height: s.height),
               from: .zero, operation: .sourceOver, fraction: 1)
}

// Two test-lead sockets under the display.
for x in [370.0, 654.0] {
    let ring = NSRect(x: x - 52, y: 150, width: 104, height: 104)
    color(0x14171C).setFill()
    NSBezierPath(ovalIn: ring).fill()
    color(0xFFC800, 0.9).setStroke()
    let inner = NSBezierPath(ovalIn: ring.insetBy(dx: 26, dy: 26))
    inner.lineWidth = 8
    inner.stroke()
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "\(outDir)/icon_1024.png"))
print("wrote \(outDir)/icon_1024.png (\(rep.pixelsWide)x\(rep.pixelsHigh))")
