import MetrCore
import SwiftUI

/// The Settings content (D-02, D-06): a grouped Form, the System Settings look, with the one Refresh
/// speed pop-up and its always-visible footnote. No custom background, material or glass: the grouped
/// Form is standard content and the system draws it (UI-SPEC Glass policy). The Open at login switch
/// joins this Form in 04-03, and nothing else is ever added (D-02).
struct SettingsView: View {
    @AppStorage private var speed: String

    /// The footnote doubles as the pop-up's accessibility hint, so the reason is spoken too.
    private static let footnote = String(
        localized: "Updates less often to save battery. Metr also does this automatically in Low Power Mode.")

    init(preferences: UserDefaults) {
        _speed = AppStorage(
            wrappedValue: RefreshSpeed.normal.rawValue, RefreshSpeed.defaultsKey, store: preferences)
    }

    var body: some View {
        Form {
            // The first Section's first row is reserved for the Open at login switch (04-03).
            Section {
                Picker("Refresh speed", selection: $speed) {
                    Text("Normal").tag(RefreshSpeed.normal.rawValue)
                    Text("Energy Saver").tag(RefreshSpeed.energySaver.rawValue)
                }
                .pickerStyle(.menu)
                .accessibilityHint(Self.footnote)
            } footer: {
                Text(Self.footnote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        // Intrinsic height: a grouped Form is a scroll view and would otherwise take any height it is
        // offered. The window measures this height once (see SettingsWindowController).
        .fixedSize(horizontal: false, vertical: true)
    }
}
