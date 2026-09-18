import AppKit
import SwiftUI

/// Gives the menu bar panel its translucent material and rounded corners, and
/// snaps its window back down to the content's height.
///
/// `MenuBarExtra(.window)` ships no material of its own on macOS 26 — dumped
/// from a live panel, its content view holds only two flat `_NSGraphicsView`s,
/// one an opaque grey fill. The material is added the way remote-mac does it:
/// an `NSVisualEffectView` *below* the existing views, with the window's
/// background cleared, and none of their layers rewritten.
///
/// Two earlier attempts shipped a panel that drew nothing (1.2.2, and
/// 1.0.0-beta), which led to the conclusion that `MenuBarExtra` cannot take a
/// material in a Release build — and then to replacing it with a hand-rolled
/// `NSPanel` (1.3.0), which broke how the panel opens and dismisses. All of
/// that was wrong. The material is fine in Release; what both failures had in
/// common was a missing `window.hasShadow = true` alongside the cleared
/// background. See `styleWindow()`.
///
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

    /// Whether the heights the panel has been asked to take are failing to
    /// settle on one value.
    ///
    /// The signal is a height *returning* after the panel has moved away from
    /// it. A genuine content change — a row arriving — steps to a new height
    /// and stays there, never revisiting the old one, so it must not be
    /// mistaken for the loop; only an A-B-A pattern means the measurement and
    /// the window disagree and are chasing each other.
    ///
    /// Half-point rounding matches the sub-point tolerance in `fittedFrame`, so
    /// jitter below the threshold that would actually resize the window does
    /// not read as oscillation.
    nonisolated static func isOscillating(_ heights: [CGFloat]) -> Bool {
        guard heights.count >= 4 else { return false }
        let keys = heights.suffix(4).map { ($0 * 2).rounded() }
        // Collapse runs of the same height: [400, 420, 420, 420] settles,
        // while [400, 420, 400, 420] keeps coming back.
        var transitions: [CGFloat] = []
        for key in keys where key != transitions.last { transitions.append(key) }
        return transitions.count > Set(transitions).count
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
            // No window means the panel just closed; nothing to follow. Forget
            // the fitted height too, so the next presentation re-fits from
            // scratch instead of matching a stale value and skipping.
            guard window != nil else {
                lastFittedHeight = nil
                recentHeights.removeAll()
                return
            }
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

        /// Rounds the panel's own window and gives it a shadow.
        ///
        /// Window-level only, and deliberately minimal — see the note on the
        /// type for what happens when this reaches further.
        /// Rounds the panel, gives it a shadow, and slots an
        /// `NSVisualEffectView` underneath so the desktop reads through it.
        ///
        /// `MenuBarExtra(.window)` ships no material of its own on macOS 26 —
        /// dumped from a live panel, its content view holds only two flat
        /// `_NSGraphicsView`s, one an opaque grey fill. Clearing the window's
        /// background and adding the backdrop *below* the existing views (never
        /// rewriting their layers) is what remote-mac does, and it works here
        /// too.
        ///
        /// **`hasShadow` is load-bearing, not decoration.** Dropping it while
        /// `backgroundColor` is cleared leaves the window with no layer forcing
        /// a background draw, and the panel comes up as an empty rectangle —
        /// that is exactly what shipped in 1.0.0-beta, where a merged `guard`
        /// swallowed this line. Verified both ways on Release builds: material
        /// with the shadow renders fully; the same build without it renders
        /// nothing. The earlier 1.2.2 failure was read as "Release breaks the
        /// material" and it was never that.
        ///
        /// Idempotent: `viewDidMoveToWindow` fires again whenever the panel is
        /// rebuilt, and a second effect view would stack another wash of tint.
        private func styleWindow() {
            guard let window else { return }
            window.hasShadow = true
            guard let content = window.contentView else { return }
            window.isOpaque = false
            window.backgroundColor = .clear

            content.wantsLayer = true
            content.layer?.cornerRadius = Self.cornerRadius
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true

            guard !content.subviews.contains(where: { $0 is Backdrop }) else { return }
            let backdrop = Backdrop()
            // `.menu` is the thinnest of the popover materials, which is the point.
            backdrop.material = .menu
            backdrop.blendingMode = .behindWindow
            // .active, not .followsWindowActiveState: the panel resigns key as
            // soon as the user clicks another app, and a backdrop that goes
            // solid grey on the way out is the bug this came to fix.
            backdrop.state = .active
            backdrop.autoresizingMask = [.width, .height]
            backdrop.frame = content.bounds
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = Self.cornerRadius
            backdrop.layer?.cornerCurve = .continuous
            backdrop.layer?.masksToBounds = true
            content.addSubview(backdrop, positioned: .below, relativeTo: nil)
        }

        /// A marker class, so the idempotence check cannot mistake some other
        /// effect view SwiftUI may park in the panel for ours.
        final class Backdrop: NSVisualEffectView {}

        /// Matches the rounding `MenuBarExtra(.window)` draws for itself.
        static let cornerRadius: CGFloat = 11

        /// Height the window was last fitted to, so the follow loop can tell a
        /// real content change from "nothing happened since the last tick".
        private var lastFittedHeight: CGFloat?

        /// The last few heights this view asked the window to take.
        ///
        /// The guard on `lastFittedHeight` alone only catches a height that
        /// repeats *immediately*; it cannot see an A-B-A-B oscillation, which is
        /// exactly the shape this loop takes. See `isOscillating`.
        private var recentHeights: [CGFloat] = []

        /// True once the recent heights stop converging on a single value.
        ///
        /// Two distinct heights alternating means the measurement disagrees with
        /// what the window becomes when it is applied — resizing again would
        /// just feed the loop, so the fit is abandoned until the content really
        /// changes.
        private var isOscillating: Bool {
            PopoverPanelStyler.isOscillating(recentHeights)
        }

        func refit() {
            // After the in-flight layout pass: the superview's frame is stale
            // until SwiftUI has finished laying the new content out.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }

                // Measure what the content *wants*, not what the window
                // currently gives it.
                //
                // This view is installed with `.background(...)`, so its
                // superview is sized to match the popover — which is sized by
                // the window this code resizes. Measuring that superview closes
                // a feedback loop: window height → SwiftUI layout → measured
                // height → setFrame → window height. While the two agree it is
                // quiet, but any disagreement of more than a point sets it
                // oscillating, and the window then grows and collapses on a
                // loop while the content, pinned to its bottom-right, appears
                // to crawl across the panel from the top-left. That is the bug
                // reported against 1.0.0 through 1.0.2.
                //
                // `fittingSize` on the hosting view is the intrinsic height of
                // the SwiftUI content and does not depend on the window, so
                // feeding it back cannot drive the loop.
                let intrinsic = self.hostingView?.fittingSize.height ?? 0
                let measured = intrinsic > 0 ? intrinsic : (self.superview?.frame.height ?? 0)

                guard let frame = PopoverPanelStyler.fittedFrame(
                    for: window.frame,
                    contentHeight: measured) else {
                    // Converged: the window already fits. Forget the history so
                    // a later, genuine content change starts from a clean slate.
                    self.recentHeights.removeAll()
                    return
                }

                // Only act when the content height actually moved since the
                // last fit. `setFrame(display: true)` forces a redraw of the
                // whole window and the follow loop calls this ten times a
                // second.
                guard self.lastFittedHeight != measured else { return }

                self.recentHeights.append(measured)
                if self.recentHeights.count > 6 { self.recentHeights.removeFirst() }
                guard !self.isOscillating else { return }

                self.lastFittedHeight = measured
                window.setFrame(frame, display: true)
            }
        }

        /// The `NSHostingView` this styler lives inside, if it can be found.
        ///
        /// Walked rather than assumed: SwiftUI is free to insert containers
        /// between the background view and the hosting view, and the exact depth
        /// is not contractual.
        private var hostingView: NSView? {
            var candidate: NSView? = self.superview
            while let view = candidate {
                if String(describing: type(of: view)).contains("NSHostingView") { return view }
                candidate = view.superview
            }
            return nil
        }
    }
}
