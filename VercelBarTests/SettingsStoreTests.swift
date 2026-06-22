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

    func test_perProjectOptIn_defaultsToEnabled() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertTrue(s.isProjectEnabled("dashboard"))
        s.setProject("dashboard", enabled: false)
        XCTAssertFalse(s.isProjectEnabled("dashboard"))
        s.setProject("dashboard", enabled: true)
        XCTAssertTrue(s.isProjectEnabled("dashboard"))
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

    func test_disablingTwoProjectsIsIndependent() {
        let s = SettingsStore(defaults: freshDefaults())
        s.setProject("a", enabled: false)
        s.setProject("b", enabled: false)
        s.setProject("a", enabled: true)
        XCTAssertTrue(s.isProjectEnabled("a"))
        XCTAssertFalse(s.isProjectEnabled("b"))
    }

    func test_pollIntervalGetterClampsStoredSubMinimum() {
        let d = freshDefaults()
        d.set(2, forKey: "pollIntervalSeconds")   // simulate an out-of-band sub-minimum value
        XCTAssertEqual(SettingsStore(defaults: d).pollIntervalSeconds, 10)
    }
}
