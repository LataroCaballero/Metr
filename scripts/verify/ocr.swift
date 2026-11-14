// On-device text recognition of PNG files for the L10N-01 render gates (04-06).
//
// Usage:  metr-ocr <png>...            prints "<file>\t<recognized line>" per observation
//         metr-ocr --self-test <dir>   draws four planted PNGs into <dir>, reads them back, and exits
//                                      0 only when recognition returns each planted text
//
// Vision runs on device; nothing here touches the network. The tool reads only the PNG paths it is
// given and, in --self-test mode, writes only the four planted files inside <dir>.
import AppKit
import Foundation
import Vision

func recognize(_ path: String) -> [String] {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write(Data("metr-ocr: cannot read \(path)\n".utf8))
        return []
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US", "es-ES"]
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do {
        try handler.perform([request])
    } catch {
        FileHandle.standardError.write(Data("metr-ocr: recognition failed for \(path): \(error)\n".utf8))
        return []
    }
    let observations = request.results ?? []
    return observations.compactMap { $0.topCandidates(1).first?.string }
}

/// Draws `text` in the 13 pt system font on a white 2x canvas and writes it as PNG.
func drawPlanted(_ text: String, to path: String) throws {
    let font = NSFont.systemFont(ofSize: 13)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    let width = Int(ceil(size.width)) + 24
    let height = Int(ceil(size.height)) + 16
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw NSError(domain: "metr-ocr", code: 1) }
    rep.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw NSError(domain: "metr-ocr", code: 2) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    string.draw(at: NSPoint(x: 12, y: 8))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "metr-ocr", code: 3) }
    try data.write(to: URL(fileURLWithPath: path))
}

func selfTest(_ dir: String) -> Int32 {
    let planted: [(file: String, text: String, matches: (String) -> Bool)] = [
        ("selftest-es-leftover.png", "Open at login", { $0.contains("Open at login") }),
        ("selftest-es-truncation.png", "Velocidad de actualiz\u{2026}", { line in
            line.hasSuffix("\u{2026}") || line.hasSuffix("...")
        }),
        ("selftest-es-number.png", "Memoria 12.5 GB", { $0.contains("12.5") }),
        ("selftest-en-number.png", "Memory 12,5 GB", { $0.contains("12,5") }),
    ]
    var failed = false
    for item in planted {
        let path = (dir as NSString).appendingPathComponent(item.file)
        do {
            try drawPlanted(item.text, to: path)
        } catch {
            print("SELF-TEST FAIL: could not draw \(item.file): \(error)")
            failed = true
            continue
        }
        let lines = recognize(path)
        if lines.contains(where: item.matches) {
            print("SELF-TEST ok \(item.file): \(lines.joined(separator: " | "))")
        } else {
            print("SELF-TEST FAIL \(item.file): read back \(lines) for planted \"\(item.text)\"")
            failed = true
        }
    }
    return failed ? 1 : 0
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--self-test" {
    guard args.count == 2 else {
        FileHandle.standardError.write(Data("usage: metr-ocr --self-test <dir>\n".utf8))
        exit(2)
    }
    exit(selfTest(args[1]))
}
guard !args.isEmpty else {
    FileHandle.standardError.write(Data("usage: metr-ocr <png>... | --self-test <dir>\n".utf8))
    exit(2)
}
// Recognize the files concurrently (Vision requests are independent) and print in argument order.
var recognized = [[String]](repeating: [], count: args.count)
let lock = NSLock()
DispatchQueue.concurrentPerform(iterations: args.count) { index in
    let lines = recognize(args[index])
    lock.lock()
    recognized[index] = lines
    lock.unlock()
}
for (index, path) in args.enumerated() {
    for line in recognized[index] {
        print("\(path)\t\(line)")
    }
}
