import XCTest
@testable import DeployBar

/// Removing a provider is the one moment the project list is expected to change.
/// The row cache has to be told, or the removed account's projects keep painting
/// from disk on the next launch — a poll that fetches nothing never overwrites
/// the snapshot.
@MainActor
final class AccountRemovalCacheTests: XCTestCase {

    private struct StubClient: DeploymentProviderClient {
        var projs: [Project]
        func deployments(limit: Int) async throws -> [Deployment] { [] }
        func projects() async throws -> [Project] { projs }
    }

    /// Builds a store over two keychain accounts sharing one defaults suite, so a
    /// second store can be built against the same disk state.
    private func makeStores(suite: String) -> (AccountStore, SettingsStore) {
        let defaults = UserDefaults(suiteName: suite)!
        let accountStore = AccountStore(defaults: defaults,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        return (accountStore, SettingsStore(defaults: defaults))
    }

    func test_removingAnAccountDropsItsProjectsImmediately() async {
        let (accountStore, settings) = makeStores(suite: UUID().uuidString)
        let keep = accountStore.addKeychainAccount(provider: .vercel, label: "Keep", token: "t1")
        let drop = accountStore.addKeychainAccount(provider: .vercel, label: "Drop", token: "t2")

        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { [keep] account, _ in
                StubClient(projs: account.id == keep.id
                           ? [Project(id: "keep", name: "keeper")]
                           : [Project(id: "drop", name: "dropper")])
            },
            reloadToken: { nil }, authRetryBackoff: .zero)

        await store.poll()
        XCTAssertEqual(store.sourcedProjects.count, 2)

        accountStore.removeAccount(drop)
        await store.accountsChanged()

        XCTAssertEqual(store.sourcedProjects.map(\.project.id), ["keep"],
                       "the removed account's project must leave the list")
    }

    /// The disk snapshot has to be rewritten at removal time — waiting for a
    /// successful poll is not enough when the removed account was the only source.
    func test_removingTheLastAccountClearsTheCacheOnDisk() async {
        let suite = UUID().uuidString
        let (accountStore, settings) = makeStores(suite: suite)
        let only = accountStore.addKeychainAccount(provider: .vercel, label: "Only", token: "t1")

        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, _ in StubClient(projs: [Project(id: "p", name: "web")]) },
            reloadToken: { nil }, authRetryBackoff: .zero)

        await store.poll()
        XCTAssertFalse(settings.cachedRows.projects.isEmpty, "precondition: cache written")

        accountStore.removeAccount(only)
        await store.accountsChanged()

        XCTAssertTrue(settings.cachedRows.projects.isEmpty,
                      "the snapshot must not outlive the account it came from")

        // And a relaunch against that disk state paints nothing.
        let (accounts2, settings2) = makeStores(suite: suite)
        let store2 = DeploymentStore(
            accountStore: accounts2, settings: settings2,
            makeClient: { _, _ in StubClient(projs: []) },
            reloadToken: { nil }, authRetryBackoff: .zero)
        XCTAssertTrue(store2.sourcedProjects.isEmpty,
                      "a removed account's projects must not come back after relaunch")
    }

    /// A removed source must not keep being replayed from `lastGood` either.
    func test_removedAccountIsNotReplayedFromLastGoodOnALaterFailedPoll() async {
        let (accountStore, settings) = makeStores(suite: UUID().uuidString)
        let keep = accountStore.addKeychainAccount(provider: .vercel, label: "Keep", token: "t1")
        let drop = accountStore.addKeychainAccount(provider: .vercel, label: "Drop", token: "t2")

        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { [keep] account, _ in
                StubClient(projs: account.id == keep.id
                           ? [Project(id: "keep", name: "keeper")]
                           : [Project(id: "drop", name: "dropper")])
            },
            reloadToken: { nil }, authRetryBackoff: .zero)

        await store.poll()
        accountStore.removeAccount(drop)
        await store.accountsChanged()
        await store.poll()

        XCTAssertFalse(store.sourcedProjects.contains { $0.project.id == "drop" },
                       "lastGood must not resurrect a removed source")
        XCTAssertNil(store.sourceErrors[drop.id],
                     "a removed account should not report errors either")
    }
}
