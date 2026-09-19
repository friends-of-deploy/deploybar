import SwiftUI
import AppKit

/// Shows the pointing-hand cursor while hovering an interactive surface.
///
/// SwiftUI doesn't change the cursor for `Link`/`Button`/`onTapGesture` content
/// on macOS, so clickable rows and icons read as plain text.
///
/// `.onHover` + `NSCursor.push()/pop()` does NOT work inside the panel that
/// `MenuBarExtra(.window)` hosts our UI in: that push targets the key window's
/// cursor stack, which a non-key menu-bar panel never adopts, so the cursor
/// stays an arrow. `.pointerStyle(.link)` (macOS 15+) installs a real pointer
/// region that the panel honors. We use it when available and fall back to the
/// push/pop path on our macOS 14 baseline.
private struct PointingHandCursor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }
}

extension View {
    /// Displays the pointing-hand cursor while the pointer is over this view.
    /// Apply to anything clickable (rows, action icons, menus).
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }

    /// Pads the geometrically centered artwork from `ActionIcon` into a
    /// rectangular cursor/tooltip/tap target shared by every action button.
    func actionIconHitArea() -> some View {
        frame(width: 18, height: 18, alignment: .center)
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
    }
}

/// An SF Symbol centered by its rendered geometry rather than its font
/// baseline. Symbols such as `doc.text.magnifyingglass` and
/// `chevron.left.forwardslash.chevron.right` have very different typographic
/// metrics; rendering them as resizable artwork keeps their visual centers on
/// one horizontal axis.
struct ActionIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16, alignment: .center)
            .actionIconHitArea()
    }
}
