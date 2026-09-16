import AppKit
import SwiftUI

/// Rounds the menu bar panel and snaps its window back down to the content's
/// height.
///
/// Deliberately does NOT try to give the panel a translucent material.
/// `MenuBarExtra(.window)` ships none of its own on macOS 26 — dumped from a
/// live panel, its content view holds only two flat `_NSGraphicsView`s, one an
/// opaque grey fill — and every attempt to supply one from here has shipped a
/// panel that draws nothing at all:
///
///   * 1.2.2 cleared the opaque fill's own layer;
///   * 1.0.0-beta added an `NSVisualEffectView` beneath the content and set
///     `window.backgroundColor = .clear`, the way remote-mac does it.
///
/// Both rendered correctly in a Debug build and failed only in Release, which
/// is what let the second one ship. The common factor is clearing the window's
/// background: a probe on a live panel showed that alone stops the draw pass.
/// remote-mac gets away with it because its panel is a different, much simpler
/// view tree; this one is not.
///
/// So the window's background is left alone. The grey fill stays, and the
/// rounding below is applied to the content view's own layer — which touches
/// nothing SwiftUI owns and has never broken anything.
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

        /// Rounds the panel's own window and gives it a shadow.
        ///
        /// Window-level only, and deliberately minimal — see the note on the
        /// type for what happens when this reaches further.
        private func styleWindow() {
            guard let window else { return }
            window.hasShadow = true
            guard let content = window.contentView else { return }
            content.wantsLayer = true
            content.layer?.cornerRadius = Self.cornerRadius
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true
        }

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
