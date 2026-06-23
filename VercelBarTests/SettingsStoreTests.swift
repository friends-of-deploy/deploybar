import XCTest
@testable import VercelBar

final class SettingsStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    func test_defaults() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertTrue(s.notifyOnFailure)
        XCTAssertTrue(s.notifyOnSuccess)
        XCTAssertFalse(s.notifyOnStarted)
        XCTAssertFalse(s.notifyOnCanceled)
        XCTAssertEqual(s.pollIntervalSeconds, 30)
    }

    func test_persistsAcrossInstances() {
        let d = freshDefaults()
        SettingsStore(defaults: d).notifyOnStarted = true
        XCTAssertTrue(SettingsStore(defaults: d).notifyOnStarted)
    }

    func test_pollIntervalClampsToMinimum() {
        let s = SettingsStore(defaults: freshDefaults())
        s.pollIntervalSeconds = 2
        XCTAssertEqual(s.pollIntervalSeconds, 10)  // clamps up to 10s minimum
    }

    func test_pollIntervalGetterClampsStoredSubMinimum() {
        let d = freshDefaults()
        d.set(2, forKey: "pollIntervalSeconds")   // simulate an out-of-band sub-minimum value
        XCTAssertEqual(SettingsStore(defaults: d).pollIntervalSeconds, 10)
    }
}
