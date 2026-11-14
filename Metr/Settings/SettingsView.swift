import AppKit
import MetrCore
import SwiftUI

/// The Settings content (D-02, D-06): a grouped Form, the System Settings look, with the Open at login
/// switch and the one Refresh speed pop-up and its always-visible footnote. No custom background,
/// material or glass: the grouped Form is standard content and the system draws it (UI-SPEC Glass
/// policy). Nothing else is ever added (D-02): the line and button under the switch are that control's
/// own status line (D-04, D-13), shown only while the projection carries a message.
struct SettingsView: View {
    @AppStorage private var speed: String
    let model: LoginItemModel

    /// The footnote doubles as the pop-up's accessibility hint, so the reason is spoken too.
    private static let footnote = String(
        localized: "Updates less often to save battery. Metr also does this automatically in Low Power Mode.")

    init(preferences: UserDefaults, loginItems: LoginItemModel) {
        model = loginItems
        _speed = AppStorage(
            wrappedValue: RefreshSpeed.normal.rawValue, RefreshSpeed.defaultsKey, store: preferences)
    }

    var body: some View {
        Form {
            Section {
                // A projection of what macOS holds: the system is read again on appear, on activation
                // and after every flip, so the switch never claims a state the system does not hold.
                Toggle(
                    "Open at login",
                    isOn: Binding(get: { model.projection.isOn }, set: { model.setEnabled($0) })
                )
                .toggleStyle(.switch)
                .disabled(!model.projection.isEnabled)
            } footer: {
                if let message = model.projection.message {
                    VStack(alignment: .leading, spacing: 8) {
                        Self.messageText(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if message != .location {
                            Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
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
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .frame(width: 480)
        // Intrinsic height: a grouped Form is a scroll view and would otherwise take any height it is
        // offered. The window measures this height once (see SettingsWindowController).
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func messageText(_ message: LoginItemMessage) -> Text {
        switch message {
        case .approval:
            return Text("Allow Metr in System Settings › General › Login Items & Extensions.")
        case .failure:
            return Text(
                "Metr couldn't change this setting. You can manage it in System Settings › General › Login Items & Extensions."
            )
        case .location:
            return Text("Move Metr to your Applications folder to open it at login.")
        }
    }
}
