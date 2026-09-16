import SwiftUI
import AppKit

/// Menu bar icon: a template glyph from Assets.xcassets, one artwork per state.
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

    /// Asset name for each state. The imagesets already declare
    /// `template-rendering-intent`, but `isTemplate` is set explicitly so the
    /// image is correct even when loaded outside the catalog's intent.
    private static func assetName(for state: IconState) -> String {
        switch state {
        case .idle:      return "MenuBarIdle"
        case .ready:     return "MenuBarReady"
        case .building:  return "MenuBarBuilding"
        case .failure:   return "MenuBarFailure"
        case .loggedOut: return "MenuBarLoggedOut"
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
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func label(for state: IconState) -> String {
        switch state {
        case .idle:      return "DeployBar — no recent deploys"
        case .ready:     return "DeployBar — all deploys ready"
        case .building:  return "DeployBar — deploy in progress"
        case .failure:   return "DeployBar — a deploy failed"
        case .loggedOut: return "DeployBar — not signed in"
        }
    }
}
