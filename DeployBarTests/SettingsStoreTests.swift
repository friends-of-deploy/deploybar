import XCTest
@testable import DeployBar

@MainActor
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

    func test_notificationMutePersistsWithoutUnfollowingProject() {
        let defaults = freshDefaults()
        let key = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "dashboard")
        let settings = SettingsStore(defaults: defaults)

        settings.setNotificationsMuted(true, for: key)

        XCTAssertTrue(settings.areNotificationsMuted(for: key))
        XCTAssertTrue(settings.isFollowed(key))
        XCTAssertTrue(SettingsStore(defaults: defaults).areNotificationsMuted(for: key))
    }

    func test_notificationMuteCanBeRemoved() {
        let settings = SettingsStore(defaults: freshDefaults())
        let key = ProjectKey(provider: .github, accountId: UUID(), projectId: "acme/app")
        settings.setNotificationsMuted(true, for: key)

        settings.setNotificationsMuted(false, for: key)

        XCTAssertFalse(settings.areNotificationsMuted(for: key))
    }

    // MARK: - Scope enablement

    func test_scopesAreEnabledByDefault() {
        let settings = SettingsStore(defaults: freshDefaults())
        XCTAssertTrue(settings.isScopeEnabled("acct|Vorciu"))
        XCTAssertTrue(settings.disabledScopeIds.isEmpty)
    }

    func test_disablingAScopePersists() {
        let defaults = freshDefaults()
        let settings = SettingsStore(defaults: defaults)

        settings.setScopeEnabled(false, for: "acct|Vorciu")

        XCTAssertFalse(settings.isScopeEnabled("acct|Vorciu"))
        // A second store over the same defaults must agree.
        XCTAssertFalse(SettingsStore(defaults: defaults).isScopeEnabled("acct|Vorciu"))
    }

    func test_reenablingAScopeRemovesItFromTheDisabledSet() {
        let settings = SettingsStore(defaults: freshDefaults())
        settings.setScopeEnabled(false, for: "acct|Vorciu")
        settings.setScopeEnabled(true, for: "acct|Vorciu")

        XCTAssertTrue(settings.isScopeEnabled("acct|Vorciu"))
        XCTAssertTrue(settings.disabledScopeIds.isEmpty)
    }

    func test_disablingOneScopeLeavesOthersEnabled() {
        let settings = SettingsStore(defaults: freshDefaults())
        settings.setScopeEnabled(false, for: "acct|Vorciu")
        XCTAssertTrue(settings.isScopeEnabled("acct|8lines"))
    }

    // MARK: - Cached organizations

    func test_cachedOrgsRoundTripPerAccount() {
        let defaults = freshDefaults()
        let settings = SettingsStore(defaults: defaults)
        let account = UUID()

        settings.cachedOrgs = [account: [Team(id: "Vorciu", slug: "Vorciu", name: "Vorciu")]]

        XCTAssertEqual(SettingsStore(defaults: defaults).cachedOrgs[account]?.first?.id, "Vorciu")
    }

    func test_legacyCachedTeamsMigrateUnderTheCLIAccount() {
        let defaults = freshDefaults()
        let settings = SettingsStore(defaults: defaults)
        let cli = UUID()
        settings.cachedTeams = [Team(id: "team_1", slug: "flipmiles", name: "Flipmiles")]

        settings.migrateCachedTeams(cliAccountId: cli)

        XCTAssertEqual(settings.cachedOrgs[cli]?.map(\.id), ["team_1"])
    }

    func test_cachedTeamsMigrationIsIdempotent() {
        let settings = SettingsStore(defaults: freshDefaults())
        let cli = UUID()
        settings.cachedTeams = [Team(id: "team_1", slug: "flipmiles", name: "Flipmiles")]

        settings.migrateCachedTeams(cliAccountId: cli)
        // A later, real org list must not be clobbered by a second migration.
        settings.cachedOrgs = [cli: [Team(id: "team_2", slug: "other", name: "Other")]]
        settings.migrateCachedTeams(cliAccountId: cli)

        XCTAssertEqual(settings.cachedOrgs[cli]?.map(\.id), ["team_2"])
    }
}

/// The channel has to survive a relaunch and has to default to stable, since
/// an install that never visited the Updates tab must not be handed betas.
@MainActor
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
