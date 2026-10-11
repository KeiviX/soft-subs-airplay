// Draws the extension's icons from SF Symbols. Usage: swift scripts/make-icons.swift Extension/Resources
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])

func png(size: Int, draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
}

func drawCentered(_ image: NSImage, in rect: CGRect) {
    let size = image.size
    image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
}

for size in [48, 96, 128, 256, 512] {
    let data = png(size: size) { rect in
        let tile = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22)
        NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.30, blue: 0.94, alpha: 1),
                            NSColor(srgbRed: 0.12, green: 0.56, blue: 0.96, alpha: 1)])!.draw(in: path, angle: -90)
        drawCentered(symbol("captions.bubble.fill", pointSize: tile.width * 0.46, color: .white), in: tile)
    }
    try! data.write(to: output.appendingPathComponent("icon-\(size).png"))
}

for size in [16, 19, 32, 38] {
    let data = png(size: size) { rect in
        drawCentered(symbol("captions.bubble", pointSize: rect.width * 0.72, color: .black), in: rect)
    }
    try! data.write(to: output.appendingPathComponent("toolbar-\(size).png"))
}
