import XCTest
@testable import DeployBar

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

/// The channel has to survive a relaunch and has to default to stable, since
/// an install that never visited the Updates tab must not be handed betas.
final class UpdateChannelSettingsTests: XCTestCase {
    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func test_defaultsToStable() {
        XCTAssertEqual(makeStore().updateChannel, .stable)
    }

    func test_persistsSelectedChannel() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = SettingsStore(defaults: defaults)

        store.updateChannel = .beta

        XCTAssertEqual(store.updateChannel, .beta)
        // A fresh store over the same domain stands in for a relaunch.
        XCTAssertEqual(SettingsStore(defaults: defaults).updateChannel, .beta)
    }

    func test_switchingBackToStablePersists() {
        let store = makeStore()
        store.updateChannel = .beta
        store.updateChannel = .stable
        XCTAssertEqual(store.updateChannel, .stable)
    }

    func test_garbageStoredValueReadsAsStable() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("nightly", forKey: "updateChannel")
        XCTAssertEqual(SettingsStore(defaults: defaults).updateChannel, .stable)
    }
}
