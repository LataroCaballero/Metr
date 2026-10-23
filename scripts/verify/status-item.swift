// Layer-25 window diff: proves the status item exists and that Metr owns no window.
// usage: swift scripts/verify/status-item.swift /path/to/Metr.app
//
// Limits: proves the item exists, NOT that the user approved it in
// System Settings > Menu Bar or that it is visible on screen.
import AppKit
import CoreGraphics
import Foundation

// Counts on-screen layer-25 windows. Control Center keeps an off-screen window for a
// known status item after the app quits (kCGWindowIsOnscreen absent), so counting
// every layer-25 window would make this check pass only on the very first launch.
func layer25WindowCount() -> Int {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return 0 }
    return list.filter {
        ($0[kCGWindowLayer as String] as? Int) == 25 && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
    }.count
}

func ownedWindowCount(pid: Int32) -> Int {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return 0 }
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.count
}

func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: status-item.swift /path/to/Metr.app\n".utf8))
    exit(2)
}
let appPath = CommandLine.arguments[1]

let before = layer25WindowCount()
let launch = run("/usr/bin/open", ["-g", "-n", appPath])
guard launch.status == 0 else {
    print("FAIL: open exited \(launch.status): \(launch.out)")
    exit(1)
}
// Wait at least 3 s, then keep polling (up to 10 s) until the window count grows.
Thread.sleep(forTimeInterval: 3)
var after = layer25WindowCount()
var waited = 3.0
while after < before + 1 && waited < 10 {
    Thread.sleep(forTimeInterval: 0.5)
    waited += 0.5
    after = layer25WindowCount()
}
let pgrep = run("/usr/bin/pgrep", ["-x", "Metr"])
let pids = pgrep.out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

var failed = false
if pids.isEmpty {
    print("FAIL: Metr is not running after launch")
    failed = true
}
if after < before + 1 {
    print("FAIL: layer-25 window count did not grow (before \(before), after \(after))")
    failed = true
}
for pid in pids {
    let owned = ownedWindowCount(pid: pid)
    if owned > 0 {
        print("FAIL: Metr (pid \(pid)) owns \(owned) window(s); expected none")
        failed = true
    }
}

_ = run("/usr/bin/pkill", ["-x", "Metr"])

if failed { exit(1) }
print("layer-25 windows: before \(before), after \(after); Metr-owned windows: 0")
print("STATUS ITEM OK")
