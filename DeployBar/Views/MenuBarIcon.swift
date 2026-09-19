import SwiftUI
import AppKit

/// Menu bar icon: a rocket glyph from Assets.xcassets, one artwork per state.
///
/// macOS needs a *template* image (pure black + alpha) for a status item so it
/// can invert for dark mode, dim an inactive bar, and knock the glyph out to
/// white when the menu is open. So the state is carried by shape, not color —
/// color still appears inside the popover as per-deployment status dots.
///
/// The one exception is `.loggedOut`, which is drawn grey: there is nothing to
/// report, so the rocket recedes instead of sitting at full contrast.
struct MenuBarIcon: View {
    let state: IconState

    /// Signed out is the only state that opts out of template rendering, so it
    /// can stay grey while every other state follows the menu bar's color.
    private var isDimmed: Bool { state == .loggedOut }

    var body: some View {
        Image(nsImage: Self.image(for: state))
            .renderingMode(isDimmed ? .original : .template)
            .accessibilityLabel(Self.label(for: state))
    }

    /// Asset name for each state. `.idle` covers a quiet bar and a bar whose
    /// last deploy succeeded — both draw the upright rocket.
    private static func assetName(for state: IconState) -> String {
        switch state {
        case .idle, .loggedOut: return "MenuBarIdle"
        case .building:         return "MenuBarDeploying"
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

        guard state == .loggedOut else {
            image.isTemplate = true
            return image
        }
        return dimmed(image)
    }

    /// Repaints the template artwork in a fixed grey. `isTemplate` must be off
    /// on the result, or AppKit discards the color and re-inks it like any
    /// other template.
    private static func dimmed(_ image: NSImage) -> NSImage {
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceOver)
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private static func label(for state: IconState) -> String {
        switch state {
        case .idle:      return "DeployBar — no recent deploys"
        case .building:  return "DeployBar — deploy in progress"
        case .failure:   return "DeployBar — a deploy failed"
        case .loggedOut: return "DeployBar — not signed in"
        }
    }
}
