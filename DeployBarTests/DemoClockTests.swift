import XCTest
@testable import DeployBar

final class DemoClockTests: XCTestCase {
    func test_frozenClockAlwaysReturnsTheSameElapsed() {
        var fake = Date(timeIntervalSince1970: 1_000)
        let clock = DemoClock(frozenAt: 42, now: { fake })

        XCTAssertEqual(clock.elapsed, 42)
        fake = Date(timeIntervalSince1970: 9_999)
        XCTAssertEqual(clock.elapsed, 42, "a frozen clock must ignore wall-clock movement")
    }

    func test_liveClockAdvancesWithWallClock() {
        var fake = Date(timeIntervalSince1970: 1_000)
        let clock = DemoClock(frozenAt: nil, now: { fake })

        XCTAssertEqual(clock.elapsed, 0, accuracy: 0.001)
        fake = Date(timeIntervalSince1970: 1_030)
        XCTAssertEqual(clock.elapsed, 30, accuracy: 0.001)
    }

    func test_nowIsStartPlusElapsed() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = DemoClock(frozenAt: 10, now: { start })
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1_010, accuracy: 0.001)
    }
}
