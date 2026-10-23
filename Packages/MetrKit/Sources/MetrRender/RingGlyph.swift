import AppKit

/// Fill state for the three menu bar rings. `nil` means "no reading yet":
/// the ring draws its track only and never an arc.
public struct GlyphState: Sendable, Equatable {
    public var cpu: Double?
    public var memory: Double?
    public var disk: Double?

    public init(cpu: Double?, memory: Double?, disk: Double?) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
    }
}

/// Draws the 56 x 18 pt three-ring menu bar glyph (CPU, Memory, Disk, fixed order).
public enum RingGlyph {
    public static let size = NSSize(width: 56, height: 18)

    // Artwork values from the UI-SPEC "Menu Bar Glyph Contract".
    private static let radius: CGFloat = 7
    private static let lineWidth: CGFloat = 2
    private static let trackAlpha: CGFloat = 0.30
    private static let centerY: CGFloat = 9

    private static func centerX(forRing index: Int) -> CGFloat { 8 + 20 * CGFloat(index) }

    /// Template image for the status item button.
    public static func image(for state: GlyphState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Headless renderer used by tests and previews. Canvas is `size * scale` pixels.
    public static func bitmap(for state: GlyphState, scale: CGFloat) -> NSBitmapImageRep {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        draw(state)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - Drawing (bottom-left origin, y grows upward)

    private static func draw(_ state: GlyphState) {
        let fills: [Double?] = [state.cpu, state.memory, state.disk]
        for (index, fill) in fills.enumerated() {
            drawRing(center: NSPoint(x: centerX(forRing: index), y: centerY), fill: fill)
        }
    }

    private static func drawRing(center: NSPoint, fill: Double?) {
        // Track: full circle behind the arc.
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(trackAlpha).setStroke()
        track.stroke()

        // No reading, or below 1%: track only (no round-cap dot).
        guard let fill, fill >= 0.01 else { return }

        let arc = NSBezierPath()
        if fill >= 0.995 {
            arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        } else {
            // 12 o'clock, clockwise.
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * CGFloat(fill),
                clockwise: true
            )
        }
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
    }
}
