/**
 * Icon.swift — the app draws its own icon at build time.
 *
 * The mark is the thing Paper actually teaches: a price line with the two levels
 * that decide the trade drawn across it — a target above, a stop below. Not a
 * chart going up. A chart with a plan on it.
 */

import AppKit

enum Icon {
    private static let ground = NSColor(srgbRed: 0.043, green: 0.055, blue: 0.071, alpha: 1)
    private static let line = NSColor(srgbRed: 0.42, green: 0.71, blue: 1.0, alpha: 1)
    private static let up = NSColor(srgbRed: 0.24, green: 0.80, blue: 0.55, alpha: 1)
    private static let down = NSColor(srgbRed: 0.94, green: 0.36, blue: 0.40, alpha: 1)

    static func draw(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let s = size
        let inset = s * 0.06
        let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = rect.width * 0.225

        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()
        ground.setFill()
        rect.fill()

        // A subtle lift at the top, so the tile has depth at 16pt as well as 1024.
        let sheen = NSGradient(colors: [
            NSColor(white: 1, alpha: 0.055),
            NSColor(white: 1, alpha: 0.0),
        ])
        sheen?.draw(in: rect, angle: -90)

        let plot = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.2)

        func level(_ fraction: CGFloat, _ colour: NSColor) {
            let y = plot.minY + plot.height * fraction
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.lineWidth = Swift.max(1, s * 0.016)
            path.setLineDash([s * 0.05, s * 0.042], count: 2, phase: 0)
            colour.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }

        level(0.90, up)   // target
        level(0.14, down) // stop

        // The price line: a pullback, then a higher high. The shape the engine is
        // looking for, drawn small enough to still read as one gesture.
        let points: [CGPoint] = [
            CGPoint(x: 0.00, y: 0.22),
            CGPoint(x: 0.18, y: 0.44),
            CGPoint(x: 0.34, y: 0.30),
            CGPoint(x: 0.52, y: 0.58),
            CGPoint(x: 0.70, y: 0.47),
            CGPoint(x: 1.00, y: 0.86),
        ].map { CGPoint(x: plot.minX + plot.width * $0.x, y: plot.minY + plot.height * $0.y) }

        let curve = NSBezierPath()
        curve.move(to: points[0])
        for p in points.dropFirst() { curve.line(to: p) }
        curve.lineWidth = Swift.max(1.5, s * 0.055)
        curve.lineJoinStyle = .round
        curve.lineCapStyle = .round
        line.setStroke()
        curve.stroke()

        return image
    }

    static func writeIconset(to directory: String) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: directory)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)

        let variants: [(String, CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]

        for (name, size) in variants {
            let image = draw(size: size)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}
