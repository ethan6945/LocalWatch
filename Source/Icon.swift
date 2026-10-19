import AppKit

// Reproducible vector artwork. Usage: swift Source/Icon.swift <iconset-directory>
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0.065, 0.09, 0.13).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0.13, 0.19, 0.23), color(0.045, 0.065, 0.105)])!.draw(in: tile, angle: -65)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: color(0.16, 0.85, 0.72, 0.16), ending: color(0.16, 0.85, 0.72, 0))!
        .draw(fromCenter: NSPoint(x: 250, y: 850), radius: 0, toCenter: NSPoint(x: 250, y: 850), radius: 680, options: [.drawsAfterEndingLocation])
    NSGraphicsContext.restoreGraphicsState()
    // A subtle inset edge keeps the silhouette readable on both desktop themes.
    let rim = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 202, yRadius: 202)
    color(0.85, 0.98, 1, 0.13).setStroke(); rim.lineWidth = 3; rim.stroke()
    // Paired local-host brackets: bold, rounded, and legible down to 16 pixels.
    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: 350, y: 645))
    mark.line(to: NSPoint(x: 245, y: 512))
    mark.line(to: NSPoint(x: 350, y: 379))
    mark.move(to: NSPoint(x: 674, y: 645))
    mark.line(to: NSPoint(x: 779, y: 512))
    mark.line(to: NSPoint(x: 674, y: 379))
    mark.lineWidth = 48; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
    color(0.84, 0.96, 0.96).setStroke(); mark.stroke()
    // Use the same SF Symbol as the menu bar for a consistent identity.
    let globeConfig = NSImage.SymbolConfiguration(pointSize: 320, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color(0.35, 0.96, 0.80)]))
    let globe = NSImage(systemSymbolName: "network", accessibilityDescription: nil)!
        .withSymbolConfiguration(globeConfig)!
    let globeSize = globe.size
    let scale = min(330 / globeSize.width, 330 / globeSize.height)
    let globeRect = NSRect(x: 512 - globeSize.width * scale / 2,
                           y: 512 - globeSize.height * scale / 2,
                           width: globeSize.width * scale, height: globeSize.height * scale)
    globe.draw(in: globeRect)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    let names: [String]
    switch pixels {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name)) }
}
