import XCTest
import AppKit
@testable import DeployBar

/// Guards the panel geometry that `MenuBarExtra` used to handle for us.
///
/// The panel is a plain `NSPanel` now — see `MenuBarPanelController` for why —
/// which means show/hide, positioning and outside-click dismissal are all ours
/// to get right. The positioning maths is the part that silently breaks (a
/// panel half off-screen next to an icon at the edge), so it is pulled out as a
/// pure function and pinned here.
final class MenuBarPanelControllerTests: XCTestCase {
    /// A 1512pt-wide screen with the menu bar at the top, like a 14" MacBook.
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 945)

    private func origin(iconMidX: CGFloat, panelWidth: CGFloat = 380) -> NSPoint {
        MenuBarPanelController.panelOrigin(
            iconFrame: NSRect(x: iconMidX - 11, y: 921, width: 22, height: 24),
            panelSize: NSSize(width: panelWidth, height: 396),
            visibleFrame: screen)
    }

    func test_panelIsCentredUnderTheIcon() {
        let o = origin(iconMidX: 756)
        XCTAssertEqual(o.x, 756 - 190, accuracy: 0.5, "centred on the icon")
    }

    func test_panelHangsBelowTheMenuBar() {
        let o = origin(iconMidX: 756)
        // The icon's bottom edge is 921; the panel hangs under it with a gap,
        // so its top (origin.y + height) must sit below that.
        XCTAssertLessThan(o.y + 396, 921, "panel must not overlap the menu bar")
    }

    /// The failure this exists to prevent: an icon near the right edge would
    /// centre a 380pt panel partly off-screen.
    func test_panelStaysOnScreenNearTheRightEdge() {
        let o = origin(iconMidX: 1500)
        XCTAssertLessThanOrEqual(o.x + 380, screen.maxX, "panel runs off the right")
        XCTAssertGreaterThanOrEqual(o.x, screen.minX)
    }

    func test_panelStaysOnScreenNearTheLeftEdge() {
        let o = origin(iconMidX: 12)
        XCTAssertGreaterThanOrEqual(o.x, screen.minX, "panel runs off the left")
        XCTAssertLessThanOrEqual(o.x + 380, screen.maxX)
    }

    /// A panel wider than the screen cannot satisfy both edges; it must still
    /// produce a sane origin rather than an inverted clamp.
    func test_panelWiderThanTheScreenIsPinnedToTheLeft() {
        let o = origin(iconMidX: 756, panelWidth: 2000)
        XCTAssertGreaterThanOrEqual(o.x, screen.minX)
    }
}
