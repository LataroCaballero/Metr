import AppKit
import MetrCore

/// Fill state for the three menu bar rings. `nil` means "no reading yet":
/// the ring draws its track only and never an arc.
public struct GlyphState: Sendable, Equatable {
    public var cpu: Double?
    public var memory: Double?
    public var disk: Double?
    /// The CPU ring never tints (D-02), so there is no `cpuTint`.
    public var memoryTint: RingTint
    public var diskTint: RingTint
    /// `accessibilityDisplayShouldIncreaseContrast`: the track alpha goes from 0.30 to 0.50.
    public var increaseContrast: Bool

    public init(
        cpu: Double?,
        memory: Double?,
        disk: Double?,
        memoryTint: RingTint = .none,
        diskTint: RingTint = .none,
        increaseContrast: Bool = false
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.memoryTint = memoryTint
        self.diskTint = diskTint
        self.increaseContrast = increaseContrast
    }

    /// True when any ring is tinted; the glyph then leaves the template path (D-07).
    public var isTinted: Bool { memoryTint != .none || diskTint != .none }
}

/// Draws the 56 x 18 pt three-ring menu bar glyph (CPU, Memory, Disk, fixed order).
public enum RingGlyph {
    public static let size = NSSize(width: 56, height: 18)

    // Artwork values from the UI-SPEC "Menu Bar Glyph Contract".
    private static let radius: CGFloat = 7
    private static let lineWidth: CGFloat = 2
    private static let trackAlpha: CGFloat = 0.30
    private static let trackAlphaIncreasedContrast: CGFloat = 0.50
    private static let centerY: CGFloat = 9

    private static func centerX(forRing index: Int) -> CGFloat { 8 + 20 * CGFloat(index) }

    /// Image for the status item button (D-07). With no ring tinted it is a template image, drawn
    /// in black so the system supplies the foreground colour. With a tint it is a regular image:
    /// every neutral part is drawn in `neutral` (the button's resolved label colour) at the same
    /// alphas, and only the tinted arc is coloured.
    public static func image(for state: GlyphState, neutral: NSColor = .black) -> NSImage {
        let tinted = state.isTinted
        let ink = tinted ? neutral : .black
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state, neutral: ink)
            return true
        }
        image.isTemplate = !tinted
        return image
    }

    /// Headless renderer used by tests and previews. Canvas is `size * scale` pixels.
    public static func bitmap(
        for state: GlyphState, scale: CGFloat, neutral: NSColor = .black
    ) -> NSBitmapImageRep {
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
        draw(state, neutral: neutral)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - Drawing (bottom-left origin, y grows upward)

    private static func draw(_ state: GlyphState, neutral: NSColor) {
        let fills: [Double?] = [state.cpu, state.memory, state.disk]
        let tints: [RingTint] = [TintLogic.cpu(), state.memoryTint, state.diskTint]
        let track = state.increaseContrast ? trackAlphaIncreasedContrast : trackAlpha
        for index in fills.indices {
            drawRing(
                center: NSPoint(x: centerX(forRing: index), y: centerY),
                fill: fills[index],
                tint: tints[index],
                neutral: neutral,
                trackAlpha: track
            )
        }
    }

    private static func arcColor(for tint: RingTint, neutral: NSColor) -> NSColor {
        switch tint {
        case .none: neutral
        case .warning: .systemYellow
        case .critical: .systemRed
        }
    }

    private static func drawRing(
        center: NSPoint, fill: Double?, tint: RingTint, neutral: NSColor, trackAlpha: CGFloat
    ) {
        // Track: full circle behind the arc. Never tinted.
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        neutral.withAlphaComponent(trackAlpha).setStroke()
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
        arcColor(for: tint, neutral: neutral).setStroke()
        arc.stroke()
    }
}
