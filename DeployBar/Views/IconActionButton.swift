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

    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            ActionIcon(systemName: systemImage)
        }
        .buttonStyle(PressableIconButtonStyle())
        // The cluster is `.secondary`; lifting the hovered icon to full contrast
        // shows which one a click would hit, since the icons sit 2pt apart.
        .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.09)) { self.hovering = hovering }
        }
        .tooltip(help)
        .pointingHandCursor()
    }
}

/// Dips the icon slightly while the mouse is down — the row behind it also
/// responds to clicks, so the icon needs its own press feedback to show which
/// target took the event.
struct PressableIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}
