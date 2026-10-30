import AppKit
import MetrCore
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

    // MARK: - Tint path (Task 1)

    private func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (-1, -1, -1, -1) }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    @Test func ringCentresSitAt8Plus20TimesIndex() {
        // Each ring's 12 o'clock stroke centre is 7 pt above its centre: x = (8 + 20 i) * 2, y-from-top = 4.
        let rep = RingGlyph.bitmap(for: GlyphState(cpu: 1, memory: 1, disk: 1), scale: 2)
        for i in 0..<3 {
            #expect(pixel(rep, x: (8 + 20 * i) * 2, y: 4).a > 0.95)
        }
    }

    @Test func gapColumnBetweenRingsIsTransparent() {
        let rep = RingGlyph.bitmap(for: GlyphState(cpu: 1, memory: 1, disk: 1), scale: 2)
        for y in 0..<rep.pixelsHigh {
            #expect(pixel(rep, x: 36, y: y).a < 0.05)
            #expect(pixel(rep, x: 76, y: y).a < 0.05)
        }
    }

    @Test func templateOnlyWhenNothingIsTinted() {
        let rest = RingGlyph.image(for: GlyphState(cpu: 0.5, memory: 0.5, disk: 0.5))
        #expect(rest.isTemplate)
        let mem = RingGlyph.image(for: GlyphState(cpu: 0.5, memory: 0.5, disk: 0.5, memoryTint: .warning))
        #expect(!mem.isTemplate)
        let disk = RingGlyph.image(for: GlyphState(cpu: 0.5, memory: 0.5, disk: 0.5, diskTint: .critical))
        #expect(!disk.isTemplate)
        #expect(GlyphState(cpu: nil, memory: nil, disk: nil, diskTint: .warning).isTinted)
        #expect(!GlyphState(cpu: nil, memory: nil, disk: nil).isTinted)
    }

    @Test func criticalDiskArcIsRedAndOnlyTheArc() {
        let state = GlyphState(cpu: 1, memory: 1, disk: 1, diskTint: .critical)
        let rep = RingGlyph.bitmap(for: state, scale: 2, neutral: .black)
        let top = pixel(rep, x: 96, y: 4)
        #expect(top.r > 0.6)
        #expect(top.g < 0.4)
        #expect(top.b < 0.4)
        // The memory ring (untinted) stays black.
        let mem = pixel(rep, x: 56, y: 4)
        #expect(mem.r < 0.1 && mem.g < 0.1 && mem.b < 0.1)
    }

    @Test func tintNeverColoursTheTrack() {
        // Disk fill 0.25: the 6 o'clock stroke centre (y = 2 + 14 pt from the top -> 32 px) is track only.
        let state = GlyphState(cpu: nil, memory: nil, disk: 0.25, diskTint: .critical)
        let rep = RingGlyph.bitmap(for: state, scale: 2)
        let bottom = pixel(rep, x: 96, y: 32)
        #expect(abs(bottom.a - 0.30) <= 0.05)
        #expect(bottom.r < 0.1 && bottom.g < 0.1 && bottom.b < 0.1)
    }

    @Test func warningMemoryArcIsOrange() {
        let state = GlyphState(cpu: nil, memory: 1, disk: nil, memoryTint: .warning)
        let rep = RingGlyph.bitmap(for: state, scale: 2)
        let top = pixel(rep, x: 56, y: 4)
        #expect(top.r > 0.8 && top.g > 0.35 && top.g < 0.75 && top.b < 0.3)
    }

    @Test func untouchedRingsRenderIdenticallyInTintedAndTemplatePaths() {
        let rest = GlyphState(cpu: 0.5, memory: 0.5, disk: 0.5)
        let tinted = GlyphState(cpu: 0.5, memory: 0.5, disk: 0.5, diskTint: .critical)
        let a = RingGlyph.bitmap(for: rest, scale: 2)
        let b = RingGlyph.bitmap(for: tinted, scale: 2, neutral: .black)
        // Rings 0 and 1 occupy x < 76 px.
        for y in 0..<a.pixelsHigh {
            for x in 0..<76 {
                let p = pixel(a, x: x, y: y)
                let q = pixel(b, x: x, y: y)
                #expect(abs(p.a - q.a) < 0.01)
            }
        }
    }

    @Test func allNilDrawsThreeTracksAndNoArcs() {
        let rep = RingGlyph.bitmap(for: GlyphState(cpu: nil, memory: nil, disk: nil), scale: 2)
        for i in 0..<3 {
            #expect(abs(pixel(rep, x: (8 + 20 * i) * 2, y: 4).a - 0.30) <= 0.05)
        }
    }

    @Test func equalFillsKeepRingOrderAndPositions() {
        let rep = RingGlyph.bitmap(for: GlyphState(cpu: 0.5, memory: 0.5, disk: 0.5), scale: 2)
        // 3 o'clock stroke centre of each ring is filled (halfway round = 6 o'clock reached), identical for all three.
        let alphas = (0..<3).map { pixel(rep, x: (8 + 20 * $0 + 7) * 2, y: 18).a }
        #expect(alphas.allSatisfy { abs($0 - alphas[0]) < 0.01 })
        #expect(alphas[0] > 0.95)
    }

    // MARK: - Letters, contrast, previews (Task 2)

    @Test func letterIsDrawnInsideRingZero() {
        let rep = RingGlyph.bitmap(for: GlyphState(cpu: nil, memory: nil, disk: nil), scale: 2)
        // Interior = within 4.5 pt of the centre (8, 9) pt. At 2x the centre is (16, 18) px from the top.
        var opaque = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let dx = Double(x) + 0.5 - 16
                let dy = Double(y) + 0.5 - 18
                if (dx * dx + dy * dy).squareRoot() <= 9, pixel(rep, x: x, y: y).a >= 0.5 { opaque += 1 }
            }
        }
        #expect(opaque >= 10)
    }

    @Test func increaseContrastRaisesTrackAlpha() {
        let normal = GlyphState(cpu: nil, memory: nil, disk: nil)
        let contrast = GlyphState(cpu: nil, memory: nil, disk: nil, increaseContrast: true)
        #expect(abs(pixel(RingGlyph.bitmap(for: normal, scale: 2), x: 16, y: 4).a - 0.30) <= 0.05)
        #expect(abs(pixel(RingGlyph.bitmap(for: contrast, scale: 2), x: 16, y: 4).a - 0.50) <= 0.05)
        // Also in the tinted path.
        let tinted = GlyphState(cpu: nil, memory: nil, disk: nil, diskTint: .warning, increaseContrast: true)
        #expect(abs(pixel(RingGlyph.bitmap(for: tinted, scale: 2), x: 16, y: 4).a - 0.50) <= 0.05)
    }

    @Test func writesPreviewsWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["METR_GLYPH_PREVIEW_DIR"], !dir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, GlyphState)] = [
            ("rest", GlyphState(cpu: 0.34, memory: 0.40, disk: 0.55)),
            ("empty", GlyphState(cpu: nil, memory: nil, disk: nil)),
            ("full", GlyphState(cpu: 1, memory: 1, disk: 1)),
            ("memWarn", GlyphState(cpu: 0.34, memory: 0.70, disk: 0.55, memoryTint: .warning)),
            ("memCritical", GlyphState(cpu: 0.34, memory: 0.90, disk: 0.55, memoryTint: .critical)),
            ("diskWarn", GlyphState(cpu: 0.34, memory: 0.40, disk: 0.92, diskTint: .warning)),
            ("diskCritical", GlyphState(cpu: 0.34, memory: 0.40, disk: 0.96, diskTint: .critical)),
            ("contrast", GlyphState(cpu: 0.34, memory: 0.40, disk: 0.55, increaseContrast: true)),
        ]
        for (name, state) in states {
            for scale in [1, 2] {
                for dark in [false, true] {
                    let neutral: NSColor = dark ? .white : .black
                    let rep = RingGlyph.bitmap(for: state, scale: CGFloat(scale), neutral: neutral)
                    let background: (Double, Double, Double) = dark ? (0.16, 0.16, 0.18) : (1, 1, 1)
                    let png = try upscaledPNG(rep, background: background, pixelsPerPoint: 8, scale: scale)
                    let file = "glyph-\(scale)x-\(dark ? "dark" : "light")-\(name).png"
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
                }
            }
        }
    }

    /// Composites over an opaque background and upscales with nearest-neighbour sampling.
    private func upscaledPNG(
        _ rep: NSBitmapImageRep, background: (Double, Double, Double), pixelsPerPoint: Int, scale: Int
    ) throws -> Data {
        let factor = pixelsPerPoint / scale
        let out = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide * factor, pixelsHigh: rep.pixelsHigh * factor,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<out.pixelsHigh {
            for x in 0..<out.pixelsWide {
                let p = pixel(rep, x: x / factor, y: y / factor)
                let color = NSColor(
                    deviceRed: p.r * p.a + background.0 * (1 - p.a),
                    green: p.g * p.a + background.1 * (1 - p.a),
                    blue: p.b * p.a + background.2 * (1 - p.a),
                    alpha: 1)
                out.setColor(color, atX: x, y: y)
            }
        }
        return try #require(out.representation(using: .png, properties: [:]))
    }
}
