import AppKit

// Draws Purgo's icon (gradient squircle + white sparkles) into a 1024 px PNG.
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.86, blue: 0.78, alpha: 1),
                    NSColor(calibratedRed: 0.36, green: 0.33, blue: 0.96, alpha: 1)])!.draw(in: shape, angle: -55)

let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
