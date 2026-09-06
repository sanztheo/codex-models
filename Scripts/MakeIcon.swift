import AppKit

// Original node-and-orbit mark; no provider logo or external artwork.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let green = NSColor(srgbRed: 0.16, green: 0.88, blue: 0.48, alpha: 1)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()

        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                xRadius: 202, yRadius: 202)
        NSGradient(starting: NSColor(white: 0.04, alpha: 1),
                   ending: NSColor(white: 0.12, alpha: 1))!.draw(in: tile, angle: 90)
        let track = NSBezierPath(ovalIn: NSRect(x: 239, y: 239, width: 546, height: 546))
        track.lineWidth = 44
        NSColor(white: 0.21, alpha: 1).setStroke()
        track.stroke()

        let orbit = NSBezierPath()
        orbit.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 273,
                        startAngle: 20, endAngle: 298)
        orbit.lineWidth = 44
        orbit.lineCapStyle = .round
        green.setStroke()
        orbit.stroke()

        let center = NSPoint(x: 512, y: 510)
        let nodes = [NSPoint(x: 512, y: 670), NSPoint(x: 372, y: 430), NSPoint(x: 652, y: 430)]
        for node in nodes {
            let spoke = NSBezierPath()
            spoke.move(to: center)
            spoke.line(to: node)
            spoke.lineWidth = 24
            spoke.lineCapStyle = .round
            NSColor(white: 0.9, alpha: 1).setStroke()
            spoke.stroke()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: node.x - 28, y: node.y - 28, width: 56, height: 56)).fill()
        }
        green.setFill()
        NSBezierPath(ovalIn: NSRect(x: 470, y: 468, width: 84, height: 84)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(points)x\(points)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
