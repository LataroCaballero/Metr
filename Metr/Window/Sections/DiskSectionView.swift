import MetrCore
import AppKit
import MetrRender
import SwiftUI

/// The Disk section of the window (DISK-01, DISK-02; UI-SPEC "Metric Section Contracts > Disk"):
/// every real drive the Mac has, the startup disk first, each with its free space and a used / free
/// bar. One row per APFS container, so the six system volumes of the startup disk are one row.
///
/// The rows are read-only: there is no Eject button and no other action on a volume (D-17). The
/// list is read when the window opens, on the Disk cadence and whenever a drive is mounted,
/// unmounted or renamed, with no spinner: until the first reading there are simply no rows. Rows
/// come and go with a short smooth transition (instant under Reduce Motion); nothing else here
/// animates, and the section is gated by `scripts/perf/window-cost.sh`. Only the startup disk's bar
/// ever tints (the Disk ring's own tint, one source); a full archive drive is not an alarm.
struct DiskSectionView: View {
    let store: MetricsStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    private let text = MetricText(locale: .current)

    var body: some View {
        let rows = store.volumes.value ?? []
        let unreadable = store.volumes == .unavailable
        return Form {
            Section {
                if unreadable {
                    // Calm, and it recovers by itself: the read is retried on the Disk cadence and
                    // on every mount event, and the list returns when one succeeds.
                    Text("Volumes unavailable. Metr will try again automatically.")
                        .font(.body)
                        .foregroundStyle(Color.secondary)
                } else {
                    ForEach(rows) { volume in
                        VolumeRow(
                            volume: volume, text: text,
                            tint: volume.role == .startup ? store.diskTint : .none,
                            speaks: voiceOver || switchControl
                        )
                        .transition(.opacity)
                    }
                }
            } header: {
                Text("Volumes")
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: rows.map(\.id))
    }
}

/// One drive: icon, name and free space, the kind of drive, the used fraction as a bar and the
/// figures that add up (used + free = total).
private struct VolumeRow: View {
    let volume: VolumeInfo
    let text: MetricText
    /// The bar's tint: the Disk ring's own, passed for the startup row only.
    let tint: RingTint
    /// VoiceOver or Switch Control runs: the row is built as one explicit accessibility element.
    let speaks: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: volume.role == .external ? "externaldrive" : "internaldrive")
                .font(.body)
                .imageScale(.large)
                .foregroundStyle(Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: volume.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The full name for a long one that was cut (the name is already sanitized).
                        .help(volume.name)
                    Spacer(minLength: 8)
                    Text(verbatim: freeText)
                        .font(.body)
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Text(verbatim: subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                if let fraction = volume.usedFraction {
                    UsageBar(fraction: fraction, tint: tint)
                        .accessibilityHidden(true)
                }
                if let caption = usedCaption {
                    Text(verbatim: caption)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 8)
        .modifier(VolumeRowAccessibility(enabled: speaks, label: spokenLabel))
    }

    /// "Macintosh HD, Startup disk, 210 GB free of 494 GB"; without capacity figures, the name and
    /// the kind only (no half-empty sentence).
    private var spokenLabel: String {
        guard let free = volume.freeBytes, let total = volume.totalBytes else {
            return "\(volume.name), \(subtitleText)"
        }
        return String(
            localized:
                "\(volume.name), \(subtitleText), \(text.byteTotal(UInt64(max(0, free)))) free of \(text.byteTotal(UInt64(max(0, total))))"
        )
    }

    /// "210 GB free", or the em dash when the volume reported no capacity.
    private var freeText: String {
        guard let free = volume.freeBytes else { return "—" }
        return String(localized: "\(text.byteTotal(UInt64(max(0, free)))) free")
    }

    /// "250 GB used of 460 GB". nil when the volume reported no capacity: no half-empty line.
    private var usedCaption: String? {
        guard let used = volume.usedBytes, let total = volume.totalBytes else { return nil }
        return String(localized: "\(text.byteTotal(UInt64(max(0, used)))) used of \(text.byteTotal(UInt64(max(0, total))))")
    }

    private var subtitleText: String {
        switch volume.role {
        case .startup: String(localized: "Startup disk")
        case .internal: String(localized: "Internal")
        case .external: String(localized: "External")
        }
    }
}

/// The spoken form of a volume row, applied only while VoiceOver or Switch Control runs (the same
/// rule as the CPU core rows: an explicit element built on every row is wasted work for everyone
/// else, and the plain texts stay readable without it).
private struct VolumeRowAccessibility: ViewModifier {
    let enabled: Bool
    let label: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
        }
    }
}

/// The used fraction of a drive: an 8 pt capsule on a quiet track. The fill is the primary color;
/// only the startup disk's bar takes the Disk ring's tint (orange, then red), through `TintPalette`.
private struct UsageBar: View {
    let fraction: Double
    let tint: RingTint

    private var fill: Color {
        TintPalette.color(for: tint).map(Color.init(nsColor:)) ?? Color.primary
    }

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.15))
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(fill)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
    }
}
