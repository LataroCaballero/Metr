import MetrCore
import MetrRender

extension TooltipTemplates {
    /// The app's tooltip sentences. Each `String(localized:)` interpolation becomes a key in
    /// `Localizable.xcstrings` (for example "Disk: %@ free of %@"), so Spanish can reorder the
    /// numbers. `nonisolated` keeps these closures off the MainActor, as `@Sendable` requires.
    nonisolated static func app() -> TooltipTemplates {
        TooltipTemplates(
            cpu: { value in
                String(localized: "CPU: \(value)")
            },
            memory: { pressure, used, total in
                switch pressure {
                case .normal: String(localized: "Memory: Normal pressure · \(used) of \(total)")
                case .warn: String(localized: "Memory: Elevated pressure · \(used) of \(total)")
                case .critical: String(localized: "Memory: Critical pressure · \(used) of \(total)")
                }
            },
            swapSuffix: { value in
                String(localized: " · Swap \(value)")
            },
            disk: { free, total in
                String(localized: "Disk: \(free) free of \(total)")
            },
            unavailable: { metric in
                switch metric {
                case .cpu: String(localized: "CPU: unavailable")
                case .memory: String(localized: "Memory: unavailable")
                case .disk: String(localized: "Disk: unavailable")
                }
            })
    }
}
