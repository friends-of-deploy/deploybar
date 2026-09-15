import XCTest
@testable import DeployBar

/// The cache exists to kill two visible glitches: an empty popover on launch and
/// a raw "team_…" id where a team name belongs.
@MainActor
final class RowCacheTests: XCTestCase {

    private struct StubClient: DeploymentProviderClient {
        var deps: [Deployment]
        var projs: [Project]
        var error: Error?
        func deployments(limit: Int) async throws -> [Deployment] {
            if let error { throw error }
            return deps
        }
        func projects() async throws -> [Project] {
            if let error { throw error }
            return projs
        }
    }

    private static func deployment(uid: String, name: String) -> Deployment {
        Deployment(uid: uid, name: name, stateRaw: "READY",
                   url: "\(name).vercel.app", createdAt: 1)
    }

    private static func team(id: String, slug: String) -> Team {
        try! JSONDecoder().decode(Team.self,
                                  from: Data(#"{"id":"\#(id)","slug":"\#(slug)","name":"\#(slug)"}"#.utf8))
    }

    /// Both stores share one UserDefaults suite, mimicking a relaunch.
    private func makeStores(suite: String) -> (AccountStore, SettingsStore) {
        let defaults = UserDefaults(suiteName: suite)!
        let accountStore = AccountStore(defaults: defaults,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { true }, reloadCLIToken: { "tok" },
                                        detectGitHubCLI: { false })
        return (accountStore, SettingsStore(defaults: defaults))
    }

    // MARK: - Row cache

    func test_rowsSurviveRelaunch() async {
        let suite = UUID().uuidString
        let (accounts1, settings1) = makeStores(suite: suite)
        let store1 = DeploymentStore(
            accountStore: accounts1, settings: settings1,
            makeClient: { _, _ in
                StubClient(deps: [Self.deployment(uid: "d1", name: "web")], projs: [], error: nil)
            },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        await store1.poll()
        XCTAssertEqual(store1.sourcedDeployments.map(\.deployment.uid), ["d1"])

        // Relaunch: a store built on the same defaults, before any poll runs.
        let (accounts2, settings2) = makeStores(suite: suite)
        let store2 = DeploymentStore(
            accountStore: accounts2, settings: settings2,
            makeClient: { _, _ in StubClient(deps: [], projs: [], error: nil) },
            reloadToken: { "tok" }, authRetryBackoff: .zero)

        XCTAssertEqual(store2.sourcedDeployments.map(\.deployment.uid), ["d1"],
                       "cached rows should paint immediately on launch")
        XCTAssertFalse(store2.isLoadingInitial,
                       "showing cached rows means we're no longer waiting for first data")
    }

    /// A failed tick must not replace good cached rows with nothing.
    func test_failedPollDoesNotOverwriteCache() async {
        let suite = UUID().uuidString
        let (accounts1, settings1) = makeStores(suite: suite)
        let store1 = DeploymentStore(
            accountStore: accounts1, settings: settings1,
            makeClient: { _, _ in
                StubClient(deps: [Self.deployment(uid: "d1", name: "web")], projs: [], error: nil)
            },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        await store1.poll()

        // Every scope now fails.
        let (accounts2, settings2) = makeStores(suite: suite)
        let store2 = DeploymentStore(
            accountStore: accounts2, settings: settings2,
            makeClient: { _, _ in
                StubClient(deps: [], projs: [], error: URLError(.notConnectedToInternet))
            },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        await store2.poll()

        XCTAssertFalse(settings2.cachedRows.deployments.isEmpty,
                       "a failed poll must leave the previous snapshot intact")
    }

    func test_staleCacheIsIgnored() async {
        let suite = UUID().uuidString
        let (accounts1, settings1) = makeStores(suite: suite)
        let store1 = DeploymentStore(
            accountStore: accounts1, settings: settings1,
            makeClient: { _, _ in
                StubClient(deps: [Self.deployment(uid: "d1", name: "web")], projs: [], error: nil)
            },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        await store1.poll()

        // Backdate the snapshot past the freshness window.
        var cache = settings1.cachedRows
        cache.savedAt = Date(timeIntervalSinceNow: -48 * 60 * 60)
        settings1.cachedRows = cache

        let (accounts2, settings2) = makeStores(suite: suite)
        let store2 = DeploymentStore(
            accountStore: accounts2, settings: settings2,
            makeClient: { _, _ in StubClient(deps: [], projs: [], error: nil) },
            reloadToken: { "tok" }, authRetryBackoff: .zero)

        XCTAssertTrue(store2.sourcedDeployments.isEmpty, "a day-old snapshot is too stale to show")
        XCTAssertTrue(store2.isLoadingInitial)
    }

    // MARK: - Team names

    func test_cachedTeamsAvailableBeforeFetch() async {
        let suite = UUID().uuidString
        let (_, settings1) = makeStores(suite: suite)
        settings1.cachedTeams = [Self.team(id: "t1", slug: "alpha")]

        let (accounts2, settings2) = makeStores(suite: suite)
        let store = DeploymentStore(
            accountStore: accounts2, settings: settings2,
            makeClient: { _, _ in StubClient(deps: [], projs: [], error: nil) },
            reloadToken: { "tok" }, authRetryBackoff: .zero)

        // Name is known before /v2/teams has been called at all.
        XCTAssertEqual(store.rowScopeLabel(accountId: accounts2.cliAccount!.id, teamId: "t1"), "alpha")
    }

    /// The bug this fixes: an unknown team rendered as "team_xasdfknasd".
    func test_unknownTeamHasNoLabelRatherThanRawId() async {
        let (accounts, settings) = makeStores(suite: UUID().uuidString)
        let store = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { _, _ in StubClient(deps: [], projs: [], error: nil) },
            reloadToken: { "tok" }, authRetryBackoff: .zero)

        XCTAssertNil(store.rowScopeLabel(accountId: accounts.cliAccount!.id,
                                         teamId: "team_xasdfknasd"))
        XCTAssertNil(store.rowScopeLabelIgnoringFilter(accountId: accounts.cliAccount!.id,
                                                       teamId: "team_xasdfknasd"))
    }

    /// Restored rows are already-seen state, not fresh events to notify about.
    func test_restoredRowsDoNotRenotify() async {
        let suite = UUID().uuidString
        let (accounts1, settings1) = makeStores(suite: suite)
        let store1 = DeploymentStore(
            accountStore: accounts1, settings: settings1,
            makeClient: { _, _ in
                StubClient(deps: [Self.deployment(uid: "d1", name: "web")], projs: [], error: nil)
            },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        await store1.poll()

        let (accounts2, settings2) = makeStores(suite: suite)
        let store2 = DeploymentStore(
            accountStore: accounts2, settings: settings2,
            makeClient: { _, _ in
                StubClient(deps: [Self.deployment(uid: "d1", name: "web")], projs: [], error: nil)
            },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        // Same deployment comes back on the first poll after restore. With the
        // baseline seeded from cache this is a no-op rather than a "ready" event.
        await store2.poll()

        XCTAssertEqual(store2.sourcedDeployments.map(\.deployment.uid), ["d1"])
    }
}
