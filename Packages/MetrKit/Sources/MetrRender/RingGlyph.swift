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

    /// Every artwork value in one place (UI-SPEC "Menu Bar Glyph Contract"). The only permitted
    /// alternates, if the letters are soft at 1x, are diameter 14 (gap 5), stroke 1.5 and letter 7.
    /// If the letters stay soft, set `drawsLetters` to false (bare rings) and flag it to the owner (D-06).
    private struct Metrics {
        static let diameter: CGFloat = 16
        static let stroke: CGFloat = 2
        static let letter: CGFloat = 8
        static let gap: CGFloat = 4
        /// D-06 fallback switch. Never flip it silently: report it in the SUMMARY.
        static let drawsLetters = true

        static let trackAlpha: CGFloat = 0.30
        static let trackAlphaIncreasedContrast: CGFloat = 0.50
        static let centerY: CGFloat = 9
        static let letters = ["C", "M", "D"]

        /// Centre of the stroke, so the outer edge of the ring is `diameter`.
        static var radius: CGFloat { (diameter - stroke) / 2 }
        static var leadingPadding: CGFloat { (56 - (3 * diameter + 2 * gap)) / 2 }
        static func centerX(forRing index: Int) -> CGFloat {
            leadingPadding + diameter / 2 + (diameter + gap) * CGFloat(index)
        }
    }

    private static var radius: CGFloat { Metrics.radius }
    private static var lineWidth: CGFloat { Metrics.stroke }
    private static var trackAlpha: CGFloat { Metrics.trackAlpha }
    private static var trackAlphaIncreasedContrast: CGFloat { Metrics.trackAlphaIncreasedContrast }
    private static var centerY: CGFloat { Metrics.centerY }

    private static func centerX(forRing index: Int) -> CGFloat { Metrics.centerX(forRing: index) }

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
            let center = NSPoint(x: centerX(forRing: index), y: centerY)
            drawRing(center: center, fill: fills[index], tint: tints[index], neutral: neutral, trackAlpha: track)
            if Metrics.drawsLetters {
                drawLetter(index, center: center, neutral: neutral)
            }
        }
    }

    /// The letter font and the width of each letter are fixed, so they are created and measured
    /// once. Building the font and laying out an attributed string on every redraw was the largest
    /// single cost of a glyph change (FND-03 profile). Drawing happens on the main thread only.
    private nonisolated(unsafe) static let letterFont = NSFont.systemFont(ofSize: Metrics.letter, weight: .semibold)
    private static let letterWidths: [CGFloat] = Metrics.letters.map { letter in
        NSAttributedString(string: letter, attributes: [.font: letterFont]).size().width
    }

    /// Letters are neutral elements (never tinted). Centred on cap height rather than the line box,
    /// horizontally by measured width, with the origin snapped to whole device pixels.
    private static func drawLetter(_ index: Int, center: NSPoint, neutral: NSColor) {
        let font = letterFont
        let text = NSAttributedString(
            string: Metrics.letters[index], attributes: [.font: font, .foregroundColor: neutral])
        let width = letterWidths[index]
        let scale = NSGraphicsContext.current.map { $0.cgContext.userSpaceToDeviceSpaceTransform.a } ?? 1
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let baseline = snap(center.y - font.capHeight / 2)
        let origin = NSPoint(x: snap(center.x - width / 2), y: baseline + font.descender)
        text.draw(at: origin)
    }

    private static func arcColor(for tint: RingTint, neutral: NSColor) -> NSColor {
        // One definition of Elevated (orange) and Critical (red) for the whole app.
        TintPalette.color(for: tint) ?? neutral
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
