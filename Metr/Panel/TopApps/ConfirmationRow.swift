import SwiftUI

/// The inline Force Quit confirmation (PROC-06, D-14; UI-SPEC "Inline Force Quit confirmation").
///
/// It replaces the row's content in place: no alert window, no sheet, no system dialog, so the
/// popover never closes because of it. Cancel carries the cancel action (Esc). Force Quit has the
/// destructive role and no keyboard shortcut, and nothing here is a default button or takes
/// initial focus, so Return never force quits (T-02-32). The name of what is about to be killed
/// wraps over two lines instead of truncating, so the user always sees all of it (E8 long-text).
struct ConfirmationRow: View {
    enum Variant: Equatable {
        /// An app, or a standalone process: its main process is force quit.
        case app(name: String)
        /// One helper of an app: only that process is force quit (D-16).
        case helper(name: String, app: String)
    }

    let variant: Variant
    let cancel: () -> Void
    let confirm: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                message
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Title and body are read as one element, before the two buttons.
            .accessibilityElement(children: .combine)
            // The buttons sit on their own row, so a long name never squeezes them (E8 overflow).
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Force Quit", role: .destructive, action: confirm)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(RowFill.opacity(contrast)))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var title: some View {
        switch variant {
        case .app(let name): Text("Force quit \(name)?")
        case .helper(let name, let app): Text("Force quit \(name) in \(app)?")
        }
    }

    @ViewBuilder
    private var message: some View {
        switch variant {
        case .app: Text("Unsaved changes will be lost.")
        case .helper: Text("The app may stop responding.")
        }
    }
}
