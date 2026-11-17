// Lists the on-screen windows, one line each: <id>\t<layer>\t<x>,<y>,<w>,<h>\t<owner pid>
// Bounds are in points with a top-left origin (the same space `screencapture -R` takes). The list needs
// no Screen Recording permission: window ids, layers, bounds and owner pids are not screen content.
// usage: window-list            (compiled once to $METR_BUILD_ROOT/bin/window-list by capture-screenshots.sh)
import CoreGraphics
import Foundation

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("window-list: CGWindowListCopyWindowInfo returned nothing\n".utf8))
    exit(1)
}

for window in list {
    guard let id = window[kCGWindowNumber as String] as? Int,
        let layer = window[kCGWindowLayer as String] as? Int,
        let pid = window[kCGWindowOwnerPID as String] as? Int,
        let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
    else { continue }
    print(
        "\(id)\t\(layer)\t\(Int(bounds.origin.x.rounded())),\(Int(bounds.origin.y.rounded())),"
            + "\(Int(bounds.size.width.rounded())),\(Int(bounds.size.height.rounded()))\t\(pid)")
}
