import XCTest
import AppKit
@testable import DeployBar

/// Guards the frame math that snaps the menu bar panel back to its content.
///
/// `MenuBarExtra(.window)` grows its panel when tall content appears but does
/// not shrink it again, leaving the short content floating inside a tall
/// window — drawn as blank strips above and below it. Ported from
/// router-menu, where the same bug was measured on a live panel: the window
/// stayed 286pt while the laid-out content had already shrunk to 104pt.
///
/// DeployBar pins its list to a fixed 320pt height, so in practice the popover
/// barely changes size at all. The math is guarded all the same — the panel must
/// track whatever height it is given.
final class PopoverPanelStylerTests: XCTestCase {
    private let tall = NSRect(x: 100, y: 100, width: 380, height: 420)

    func test_shrinkKeepsTheTopEdgeAnchored() {
        let fitted = PopoverPanelStyler.fittedFrame(for: tall, contentHeight: 380)
        XCTAssertEqual(fitted, NSRect(x: 100, y: 140, width: 380, height: 380))
        // AppKit measures origin.y from the bottom of the screen, so the origin
        // has to absorb the delta or the panel slides down the screen instead
        // of staying hung from the menu bar.
        XCTAssertEqual(fitted?.maxY, tall.maxY, "the panel hangs from the menu bar")
    }

    func test_growthKeepsTheTopEdgeAnchored() {
        let fitted = PopoverPanelStyler.fittedFrame(for: tall, contentHeight: 500)
        XCTAssertEqual(fitted, NSRect(x: 100, y: 20, width: 380, height: 500))
        XCTAssertEqual(fitted?.maxY, tall.maxY)
    }

    func test_nearMissesDoNotResize() {
        // Sub-point deltas would make every layout pass nudge the window.
        XCTAssertNil(PopoverPanelStyler.fittedFrame(for: tall, contentHeight: 420.5))
        XCTAssertNil(PopoverPanelStyler.fittedFrame(for: tall, contentHeight: 420))
    }

    func test_degenerateContentHeightIsIgnored() {
        // Zero is what the hosting view reports before layout; acting on it
        // would collapse the panel to nothing.
        XCTAssertNil(PopoverPanelStyler.fittedFrame(for: tall, contentHeight: 0))
        XCTAssertNil(PopoverPanelStyler.fittedFrame(for: tall, contentHeight: -50))
    }

    // MARK: - Oscillation

    // The panel bug behind 1.0.0-1.0.2: the window grew and collapsed on a
    // loop while the content, pinned to its bottom-right, appeared to crawl
    // across the panel from the top-left. The measured height alternated
    // instead of settling, so a guard that only compares against the previous
    // value never fired.

    func test_settledHeightsAreNotOscillation() {
        XCTAssertFalse(PopoverPanelStyler.isOscillating([420, 420, 420, 420]))
    }

    func test_alternatingHeightsAreOscillation() {
        XCTAssertTrue(PopoverPanelStyler.isOscillating([400, 420, 400, 420]))
    }

    func test_aGenuineContentChangeIsNotOscillation() {
        // A row arriving steps to a new height and stays there.
        XCTAssertFalse(PopoverPanelStyler.isOscillating([400, 420, 420, 420]))
    }

    func test_tooFewSamplesNeverReportOscillation() {
        // Startup must be free to resize; the loop only exists once a pattern
        // has had a chance to form.
        XCTAssertFalse(PopoverPanelStyler.isOscillating([400, 420]))
        XCTAssertFalse(PopoverPanelStyler.isOscillating([400, 420, 400]))
    }

    func test_subPointJitterIsNotOscillation() {
        // Differences below the threshold that would actually resize the
        // window must not trip the breaker.
        XCTAssertFalse(PopoverPanelStyler.isOscillating([420, 420.2, 420, 420.1]))
    }
}
