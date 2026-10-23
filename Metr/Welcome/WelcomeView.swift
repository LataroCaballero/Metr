import AppKit
import MetrCore
import MetrRender
import SwiftUI

/// First-launch welcome content (D-14, UI-SPEC "First-Launch Welcome Window Contract").
/// Top to bottom: icon, headline, mini rings, instruction, tip, buttons. No custom background:
/// the window material comes from the system, and accent colour appears only on Done.
struct WelcomeView: View {
    let onDone: () -> Void
    /// True once Open Menu Bar Settings could not reach the Menu Bar pane itself (D-16): the tip
    /// then spells the path out in words. The initializer parameter exists so the DEBUG snapshot
    /// renderer can show that state.
    @State private var usedFallback: Bool

    init(onDone: @escaping () -> Void, usedFallback: Bool = false) {
        self.onDone = onDone
        _usedFallback = State(initialValue: usedFallback)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Metr lives in your menu bar")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Image(nsImage: Self.previewGlyph)
                .renderingMode(.template)
                .resizable()
                .frame(width: 112, height: 36)
                .foregroundStyle(.primary)
                .padding(.top, 24)
                .accessibilityHidden(true)
            Text("Click the rings for details")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Text(
                usedFallback
                    ? LocalizedStringKey("Open System Settings, go to Menu Bar, and turn Metr on.")
                    : LocalizedStringKey("Don't see them? Turn Metr on in System Settings › Menu Bar.")
            )
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
            buttons
                .padding(.top, 24)
        }
        .padding(32)
        .frame(width: 420)
        .onExitCommand { onDone() }
    }

    /// The same renderer as the menu bar, template path, shown at 2x as a preview.
    private static var previewGlyph: NSImage {
        RingGlyph.image(for: GlyphState(cpu: 0.34, memory: 0.42, disk: 0.6))
    }

    /// Trailing button group. ViewThatFits wraps it into a column rather than clipping when the
    /// localized labels do not fit on one row.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                openSettingsButton
                doneButton
            }
            VStack(alignment: .trailing, spacing: 8) {
                openSettingsButton
                doneButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Tries the deep link, then System Settings itself. Anything but a clean deep link (including a
    /// total failure) swaps the tip, so the button always visibly does something. The window stays open.
    private var openSettingsButton: some View {
        Button("Open Menu Bar Settings") {
            let outcome = MenuBarSettingsLink.open(using: { NSWorkspace.shared.open($0) })
            if outcome != .deepLink { usedFallback = true }
        }
        .buttonStyle(.bordered)
    }

    private var doneButton: some View {
        Button("Done", action: onDone)
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
    }
}
