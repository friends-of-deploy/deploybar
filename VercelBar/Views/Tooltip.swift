import SwiftUI
import AppKit

/// Shows a native hover tooltip that works inside `MenuBarExtra(.window)`.
///
/// SwiftUI's `.help(_:)` attaches an AppKit tooltip to the hosting view, but
/// that tracking never fires inside the panel `MenuBarExtra(.window)` hosts its
/// content in, so `.help` strings silently never appear on our macOS 14
/// baseline. Overlaying a real `NSView` with its own `toolTip` participates in
/// the panel's tracking and displays reliably.
private struct TooltipView: NSViewRepresentable {
    let message: String

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughTooltipNSView()
        view.toolTip = message
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.toolTip = message
    }
}

/// An overlay that shows a tooltip but never intercepts clicks, so controls
/// underneath it (icon buttons, `Menu`) still receive their events. Without the
/// passthrough, the overlay swallows the click that opens a `Menu`.
private final class PassthroughTooltipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Displays `message` as a native tooltip on hover. Use instead of `.help`
    /// for content inside the menu-bar panel, where `.help` does not render.
    func tooltip(_ message: String) -> some View {
        overlay(TooltipView(message: message))
    }
}
