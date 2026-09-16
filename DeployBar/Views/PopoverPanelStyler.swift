import AppKit
import SwiftUI

/// Gives the menu bar panel the rounded, shadowed surface a panel is supposed
/// to have, and snaps its window back down to the content's height.
///
/// `MenuBarExtra(.window)` draws a plain square-cornered rectangle unless the
/// window is styled, and it grows its panel for tall content without ever
/// shrinking it again. Ported from router-menu, where both were measured on a
/// live panel: a connected → disconnected flip left the window at 286pt while
/// the laid-out content had already shrunk to 104pt and been offset to y=91 —
/// a 182pt dead band drawn as blank strips above and below the content.
///
/// DeployBar pins its list to a fixed 320pt height, so its panel only changes
/// height when the optional error `StatusBar` appears or disappears. The
/// rounding is what this mainly buys here; the re-fit keeps that one
/// transition honest.
///
/// ## Two things this deliberately does NOT do
///
/// **It does not measure `window.contentView.fittingSize`.** On
/// `MenuBarExtraHostingView` that is always `(0, 0)` — verified by dumping a
/// real panel — so a sizer built on it never resizes anything. The height
/// comes from `superview` instead: the view SwiftUI lays this representable
/// out inside, which fills the panel's content and therefore reports the
/// height the window should be.
///
/// **It does not insert a backdrop into the hosting view.** An earlier
/// router-menu version cleared `window.backgroundColor` permanently and
/// spliced an `NSVisualEffectView` in beside SwiftUI's private
/// `_NSGraphicsView`s; reproduced in isolation, that stops the panel drawing
/// at all. Only the window's own layer is touched here.
struct PopoverPanelStyler: NSViewRepresentable {
    /// The corrected window frame, or nil when the current one already fits.
    ///
    /// The top edge stays anchored: AppKit measures `origin.y` from the bottom
    /// of the screen, so the origin has to absorb the height delta or the
    /// panel would slide down instead of staying hung from the menu bar.
    ///
    /// Sub-point deltas are ignored — otherwise every layout pass would nudge
    /// the window and the panel would visibly jitter.
    nonisolated static func fittedFrame(for frame: NSRect,
                                        contentHeight: CGFloat) -> NSRect? {
        // Zero is what the hosting view reports before layout has happened;
        // acting on it would collapse the panel to nothing.
        guard contentHeight > 0 else { return nil }
        let delta = contentHeight - frame.height
        guard abs(delta) > 1 else { return nil }
        var fitted = frame
        fitted.origin.y -= delta
        fitted.size.height = contentHeight
        return fitted
    }

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.refit()
    }

    static func dismantleNSView(_ view: TrackerView, coordinator: ()) {
        view.stopFollowing()
    }

    final class TrackerView: NSView {
        /// Follows the panel for as long as it is on screen.
        ///
        /// A one-shot re-fit is not enough: SwiftUI does not re-run
        /// `updateNSView` for every content change, and a height change lands a
        /// layout pass *after* the state change that caused it. Measured in
        /// router-menu — with only `updateNSView` driving it, the first
        /// transition resized and every later one did not.
        private var follow: Task<Void, Never>?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            styleWindow()
            refit()
            stopFollowing()
            // No window means the panel just closed; nothing to follow.
            guard window != nil else { return }
            follow = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, self.window != nil else { return }
                    self.refit()
                }
            }
        }

        func stopFollowing() {
            follow?.cancel()
            follow = nil
        }

        /// Gives the panel the translucent material AppKit does not.
        ///
        /// `MenuBarExtra(.window)` ships no `NSVisualEffectView` at all on
        /// macOS 26 — dumped from a live panel, its content view holds only
        /// two flat `_NSGraphicsView`s, one of them an **opaque** grey fill
        /// (`0.96, 0.96, 0.96, alpha 1.0`). That opaque rectangle is the
        /// "grey block" look; nothing behind the window shows through it.
        ///
        /// So the material has to be supplied here. Two details make this safe
        /// where an earlier router-menu attempt was not:
        ///
        ///   * The window's own `backgroundColor` is left ALONE. Clearing it
        ///     permanently is half of what made that attempt render a blank
        ///     panel.
        ///   * The opaque fill is cleared on the layer rather than by removing
        ///     the view, and the effect view goes underneath everything, so
        ///     SwiftUI's own view tree is never restructured.
        ///
        /// Idempotent: `viewDidMoveToWindow` fires again whenever the panel is
        /// rebuilt, and a second effect view would stack another wash of tint.
        private func styleWindow() {
            guard let window else { return }
            window.hasShadow = true
            guard let content = window.contentView else { return }

            // The system's opaque grey fill. Only fully-opaque layers are
            // cleared: the other graphics view is already semi-transparent and
            // carries the panel's subtle tint, which is worth keeping.
            for subview in content.subviews {
                guard let layer = subview.layer,
                      let background = layer.backgroundColor,
                      let alpha = background.components?.last, alpha > 0.99 else { continue }
                layer.backgroundColor = NSColor.clear.cgColor
            }

            guard !content.subviews.contains(where: { $0 is Backdrop }) else { return }
            let backdrop = Backdrop(frame: content.bounds)
            backdrop.material = .popover
            backdrop.blendingMode = .behindWindow
            // .active, not .followsWindowActiveState: the panel resigns key as
            // soon as the user clicks another app, and a backdrop that goes
            // solid grey on the way out is the bug this came to fix.
            backdrop.state = .active
            backdrop.autoresizingMask = [.width, .height]
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = Self.cornerRadius
            backdrop.layer?.cornerCurve = .continuous
            backdrop.layer?.masksToBounds = true
            content.addSubview(backdrop, positioned: .below, relativeTo: nil)
        }

        /// A marker class, so the idempotence check cannot mistake some other
        /// effect view for ours.
        final class Backdrop: NSVisualEffectView {}

        /// Matches the rounding `MenuBarExtra(.window)` draws for itself.
        static let cornerRadius: CGFloat = 11

        func refit() {
            // After the in-flight layout pass: the superview's frame is stale
            // until SwiftUI has finished laying the new content out.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let window = self.window,
                      // `superview`, NOT `window.contentView` — see the note on
                      // the type: the hosting view's fittingSize is always zero.
                      let host = self.superview,
                      let frame = PopoverPanelStyler.fittedFrame(
                          for: window.frame,
                          contentHeight: host.frame.height) else { return }
                window.setFrame(frame, display: true)
            }
        }
    }
}
