import SwiftUI
import AppKit

/// A tappable SF Symbol that opens a URL, with a pointing-hand cursor and tooltip.
///
/// We deliberately avoid `Link` here: on macOS `Link` installs its own AppKit
/// cursor/tracking, which overrides our `.pointingHandCursor()` (`onHover` →
/// `NSCursor`) so the pointer never changes over the icon. A plain `Button` that
/// opens the URL via `NSWorkspace` imposes no cursor of its own, letting the
/// hover-driven cursor and tooltip work — the same pattern the row body uses.
struct IconActionButton: View {
    let systemImage: String
    let url: URL
    let help: String

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Image(systemName: systemImage)
                .actionIconHitArea()
        }
        .buttonStyle(.plain)
        .tooltip(help)
        .pointingHandCursor()
    }
}
