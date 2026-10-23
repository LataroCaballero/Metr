import AppKit
import Testing

@testable import MetrRender

@Suite struct RingGlyphTests {
    /// Alpha of the pixel at the 12 o'clock stroke centre of ring 0 (scale 2).
    private func alphaAtTwelveOClock(_ state: GlyphState) -> Double {
        let rep = RingGlyph.bitmap(for: state, scale: 2)
        // Ring 0 centre is (8, 9) pt; 12 o'clock stroke centre is 7 pt above it,
        // i.e. y = 2 pt from the top. At 2x: x = 16, y-from-top = 4.
        let color = rep.colorAt(x: 16, y: 4)
        return Double(color?.alphaComponent ?? -1)
    }

    @Test func trackOnlyWhenNoReading() {
        let alpha = alphaAtTwelveOClock(GlyphState(cpu: nil, memory: nil, disk: nil))
        #expect(abs(alpha - 0.30) <= 0.05)
    }

    @Test func fullFillDrawsOpaqueArc() {
        let alpha = alphaAtTwelveOClock(GlyphState(cpu: 1.0, memory: nil, disk: nil))
        #expect(abs(alpha - 1.0) <= 0.05)
    }

    @Test func nearZeroFillDrawsTrackOnly() {
        let alpha = alphaAtTwelveOClock(GlyphState(cpu: 0.005, memory: nil, disk: nil))
        #expect(abs(alpha - 0.30) <= 0.05)
    }

    @Test func canvasIs56By18Points() {
        let rep = RingGlyph.bitmap(for: GlyphState(cpu: nil, memory: nil, disk: nil), scale: 2)
        #expect(rep.pixelsWide == 112)
        #expect(rep.pixelsHigh == 36)
    }

    @Test func imageIsTemplate() {
        let image = RingGlyph.image(for: GlyphState(cpu: nil, memory: nil, disk: nil))
        #expect(image.isTemplate)
        #expect(image.size == RingGlyph.size)
    }
}
