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

    /// Standardizes an action icon's footprint: every glyph is centered in the
    /// same fixed square, then padded into a rectangular hit target.
    ///
    /// SF Symbols have differing intrinsic widths and baselines, so a bare
    /// `Image` self-sizes to its glyph — letting `clipboard`, `globe`,
    /// `chevron…` etc. land at different positions and the icon jump when a
    /// symbol swaps. A uniform frame centers them all by one rule so a row of
    /// icons aligns. Padding plus a rectangular `contentShape` then makes the
    /// surrounding box (not just the glyph pixels) the cursor/tooltip/tap target.
    func actionIconHitArea() -> some View {
        font(.system(size: 14))   // fixed symbol size: equal cap height across glyphs
            .frame(width: 18, height: 18)
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
    }
}
