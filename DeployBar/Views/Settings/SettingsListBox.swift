import SwiftUI

/// The Mail-style list box used by the master–detail tabs: a bordered, inset
/// list with an optional add/remove strip attached to its bottom edge — one
/// framed control, not a free-floating sidebar.
///
/// `accessory` is the strip's content; pass `EmptyView()` for a plain box and
/// the strip (and its divider) disappears with it.
struct SettingsListBox<Content: View, Accessory: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            content

            if !(Accessory.self == EmptyView.self) {
                Divider()

                HStack(spacing: 0) {
                    accessory
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

/// A bare glyph button sized for `SettingsListBox`'s bottom strip, with the
/// label surviving as a tooltip — the classic add/remove control.
struct SettingsStripButton: View {
    let systemImage: String
    let help: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .help(help)
    }
}
