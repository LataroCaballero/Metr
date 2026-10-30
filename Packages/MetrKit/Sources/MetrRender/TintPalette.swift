import AppKit
import MetrCore

/// The single definition of the Elevated and Critical colors (UI-SPEC owner decision 2: one
/// Elevated color, orange, everywhere). Plan 02-03 moves the rings and the menu bar glyph onto it.
public enum TintPalette {
    /// Elevated: the system orange.
    public static var elevated: NSColor { .systemOrange }
    /// Critical: the system red.
    public static var critical: NSColor { .systemRed }

    /// The color for a tint, nil for `.none` (the caller uses its neutral color).
    public static func color(for tint: RingTint) -> NSColor? {
        switch tint {
        case .none: nil
        case .warning: elevated
        case .critical: critical
        }
    }
}
