import SwiftUI
import AppKit

/// Menu bar icon: a rocket glyph from Assets.xcassets, one artwork per state.
///
/// macOS needs a *template* image (pure black + alpha) for a status item so it
/// can invert for dark mode, dim an inactive bar, and knock the glyph out to
/// white when the menu is open. So the state is carried by shape, not color —
/// color still appears inside the popover as per-deployment status dots.
struct MenuBarIcon: View {
    let state: IconState

    var body: some View {
        Image(nsImage: Self.image(for: state))
            .renderingMode(.template)
            .accessibilityLabel(Self.label(for: state))
    }

    /// Asset name for each state, with distinct badges for deploy outcomes.
    private static func assetName(for state: IconState) -> String {
        switch state {
        case .idle:            return "MenuBarIdle"
        case .loggedOut:       return "MenuBarLoggedOut"
        case .building:         return "MenuBarDeploying"
        case .success:          return "MenuBarSucceeded"
        case .failure:          return "MenuBarFailed"
        }
    }

    static func image(for state: IconState) -> NSImage {
        let name = assetName(for: state)
        guard let image = NSImage(named: name) else {
            // Missing asset shouldn't blank the menu bar — fall back to the glyph.
            let fallback = NSImage(systemSymbolName: "triangle.fill", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 18, height: 18))
            fallback.isTemplate = true
            return fallback
        }
        image.size = NSSize(width: 18, height: 18)

        image.isTemplate = true
        return image
    }

    private static func label(for state: IconState) -> String {
        switch state {
        case .idle:      return "DeployBar — no recent deploys"
        case .building:  return "DeployBar — deploy in progress"
        case .success:   return "DeployBar — a deploy succeeded"
        case .failure:   return "DeployBar — a deploy failed"
        case .loggedOut: return "DeployBar — not signed in"
        }
    }
}
