// Measures a running process with proc_pid_rusage (RUSAGE_INFO_V4), never ps or Activity Monitor
// (RESEARCH Pitfall 4: they read ~0.3% for an app that really costs ~0.012%).
//
// Usage:  swift scripts/perf/rusage.swift <pid> <seconds>
//         swift scripts/perf/rusage.swift <pid> --snapshot
//
// Window mode prints one line:
//   RUSAGE cpu_pct=<3dp> wakeups_per_s=<2dp> footprint_mb=<1dp> wall_s=<1dp>
// Snapshot mode prints:
//   RUSAGE footprint_mb=<1dp>
// A failed rusage call exits 1.
import Darwin
import Foundation

func rusage(_ pid: pid_t) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? info : nil
}

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: rusage <pid> <seconds> | rusage <pid> --snapshot\n".utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let pid = pid_t(arguments[1]) else { usage() }

let megabyte = 1_048_576.0

if arguments[2] == "--snapshot" {
    guard let info = rusage(pid) else { exit(1) }
    print(String(format: "RUSAGE footprint_mb=%.1f", Double(info.ri_phys_footprint) / megabyte))
    exit(0)
}

guard let seconds = Double(arguments[2]), seconds > 0 else { usage() }

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

guard let first = rusage(pid) else { exit(1) }
let start = DispatchTime.now().uptimeNanoseconds
Thread.sleep(forTimeInterval: seconds)
guard let last = rusage(pid) else { exit(1) }
let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

let ticks = (last.ri_user_time &- first.ri_user_time) &+ (last.ri_system_time &- first.ri_system_time)
let cpuSeconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
let wakeups = Double(last.ri_interrupt_wkups &- first.ri_interrupt_wkups) / wall

print(String(
    format: "RUSAGE cpu_pct=%.3f wakeups_per_s=%.2f footprint_mb=%.1f wall_s=%.1f",
    cpuSeconds / wall * 100, wakeups, Double(last.ri_phys_footprint) / megabyte, wall))
