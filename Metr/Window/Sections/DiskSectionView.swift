import MetrCore
import MetrRender
import SwiftUI

/// The Disk section of the window (DISK-01, DISK-02; UI-SPEC "Metric Section Contracts > Disk"):
/// every real drive the Mac has, the startup disk first, each with its free space and a used / free
/// bar. One row per APFS container, so the six system volumes of the startup disk are one row.
///
/// The rows are read-only: there is no Eject button and no other action on a volume (D-17). The
/// list is read when the window opens and then on the Disk cadence, with no spinner: until the
/// first reading there are simply no rows. Nothing here animates; the section is gated by
/// `scripts/perf/window-cost.sh`. The mount / unmount refresh, the startup tint and the list-level
/// error line follow in the next plan.
struct DiskSectionView: View {
    let store: MetricsStore

    private let text = MetricText(locale: .current)

    var body: some View {
        let rows = store.volumes.value ?? []
        return Form {
            Section {
                ForEach(rows) { volume in
                    VolumeRow(volume: volume, text: text)
                }
            } header: {
                Text("Volumes")
            }
        }
        .formStyle(.grouped)
    }
}

/// One drive: icon, name and free space, the kind of drive, the used fraction as a bar and the
/// figures that add up (used + free = total).
private struct VolumeRow: View {
    let volume: VolumeInfo
    let text: MetricText

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
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                if let fraction = volume.usedFraction {
                    UsageBar(fraction: fraction)
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
        .accessibilityElement(children: .combine)
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

    private var subtitle: LocalizedStringKey {
        switch volume.role {
        case .startup: "Startup disk"
        case .internal: "Internal"
        case .external: "External"
        }
    }
}

/// The used fraction of a drive: an 8 pt capsule, neutral. Free space is not an alarm here (the
/// startup tint comes later), so the fill is the primary color on a quiet track.
private struct UsageBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.15))
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
    }
}
