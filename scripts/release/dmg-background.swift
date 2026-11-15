// Draws the DMG window background (UI-SPEC "DMG Window Contract"): vertical gradient #F5F5F7 to
// #E8E8ED, a #8E8E93 arrow (3 pt line, open chevron head, 64 pt long) centered at (300, 180), and the
// two hint lines in #6E6E73, SF Pro 11 pt Regular, centered at y 332 and y 352 (top-left origin).
// Measures each hint line and exits 1 if either is wider than 560 pt (never wrap, never add a size).
//
// Usage: swift scripts/release/dmg-background.swift <outdir>
// Writes <outdir>/background.png (600 x 400 px) and <outdir>/background@2x.png (1200 x 800 px, 144 dpi),
// then prints "BACKGROUND OK en=<pt> es=<pt>". The caller combines them:
//   tiffutil -cathidpicheck background.png background@2x.png -out scripts/release/dmg/background.tiff
import AppKit

let width: CGFloat = 600
let height: CGFloat = 400
let maxLine: CGFloat = 560
let hintEN = "First time? System Settings \u{203A} Privacy & Security \u{203A} Open Anyway"
let hintES = "\u{00BF}Primera vez? Ajustes del Sistema \u{203A} Privacidad y seguridad \u{203A} Abrir igualmente"

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
}

let hintFont = NSFont.systemFont(ofSize: 11, weight: .regular)
let hintAttributes: [NSAttributedString.Key: Any] = [.font: hintFont, .foregroundColor: color(0x6E6E73)]
let enWidth = (hintEN as NSString).size(withAttributes: hintAttributes).width
let esWidth = (hintES as NSString).size(withAttributes: hintAttributes).width
if enWidth > maxLine || esWidth > maxLine {
    FileHandle.standardError.write(Data(String(format: "FAIL: hint too wide en=%.1f es=%.1f (max %.0f)\n", enWidth, esWidth, maxLine).utf8))
    exit(1)
}

func render(scale: Int) -> Data {
    let pixelsWide = Int(width) * scale
    let pixelsHigh = Int(height) * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("no bitmap") }
    rep.size = NSSize(width: width, height: height)  // 1x = 72 dpi, 2x = 144 dpi
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
    NSGraphicsContext.saveGraphicsState()
    // flipped: true gives the top-left origin the spec's coordinates use
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: height)
    context.cgContext.scaleBy(x: 1, y: -1)

    NSGradient(starting: color(0xF5F5F7), ending: color(0xE8E8ED))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    // Arrow: 64 pt long, centered at (300, 180), 3 pt line, open chevron head.
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 268, y: 180))
    arrow.line(to: NSPoint(x: 332, y: 180))
    arrow.move(to: NSPoint(x: 320, y: 168))
    arrow.line(to: NSPoint(x: 332, y: 180))
    arrow.line(to: NSPoint(x: 320, y: 192))
    color(0x8E8E93).setStroke()
    arrow.stroke()

    for (text, centerY) in [(hintEN, CGFloat(332)), (hintES, CGFloat(352))] {
        let size = (text as NSString).size(withAttributes: hintAttributes)
        (text as NSString).draw(
            at: NSPoint(x: (width - size.width) / 2, y: centerY - size.height / 2),
            withAttributes: hintAttributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift <outdir>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
print(String(format: "BACKGROUND OK en=%.1f es=%.1f", enWidth, esWidth))
