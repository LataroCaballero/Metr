import Darwin
import Foundation
import MetrCore
import MetrSystem

// Dev-only probe: prints one reading per invocation so scripts/verify can compare it with the
// system's own tools. Not part of the MetrKit library product, never linked into the app.

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: metr-probe memory|disk\n".utf8))
    exit(64)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("metr-probe: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 1, let command = arguments.first else { usage() }

switch command {
case "memory":
    guard case .value(let m) = MemoryCollector().sample() else { fail("memory reading unavailable") }
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    var rawPressure: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &rawPressure, &size, nil, 0)
    print(
        "memory used=\(m.usedBytes) total=\(m.totalBytes) swap=\(m.swapUsedBytes) "
            + "freePercent=\(m.freePercent) pressure=\(rawPressure) pageSize=\(pageSize)"
    )
case "disk":
    guard case .value(let d) = DiskCollector().sample() else { fail("disk reading unavailable") }
    print(
        "disk total=\(d.totalBytes) available=\(d.availableBytes) "
            + "usedFraction=\(String(format: "%.4f", d.usedFraction))"
    )
default:
    usage()
}
