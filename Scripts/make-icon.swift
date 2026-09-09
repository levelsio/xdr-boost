import AppKit

// Original vector-drawn artwork; no downloaded assets or graphics dependencies.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.20, blue: 0.32, alpha: 1),
                   ending: NSColor(srgbRed: 0.035, green: 0.055, blue: 0.10, alpha: 1))!.draw(in: background, angle: 270)
        NSColor(srgbRed: 1, green: 0.76, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 362, y: 362, width: 300, height: 300)).fill()
        NSColor(srgbRed: 1, green: 0.83, blue: 0.36, alpha: 1).setStroke()
        for ray in 0..<8 {
            let angle = Double(ray) * .pi / 4
            let line = NSBezierPath()
            line.lineWidth = 44
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: 512 + cos(angle) * 224, y: 512 + sin(angle) * 224))
            line.line(to: NSPoint(x: 512 + cos(angle) * 302, y: 512 + sin(angle) * 302))
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
