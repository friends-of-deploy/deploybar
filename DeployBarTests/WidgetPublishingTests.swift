import XCTest
@testable import DeployBar

private let web = Project(id: "prj_web", name: "web")
private let api = Project(id: "prj_api", name: "api")
private let building = Deployment(uid: "d1", name: "web", stateRaw: "BUILDING",
                                  url: "web-1.vercel.app", createdAt: 1_700_000_000_000)

/// The store publishes followed, enabled rows after a fresh poll — and only then.
@MainActor
final class WidgetPublishingTests: XCTestCase {

    private struct StubClient: DeploymentProviderClient {
        var deps: [Deployment] = []
        var projs: [Project] = []
        var fail = false
        func deployments(limit: Int) async throws -> [Deployment] {
            if fail { throw URLError(.notConnectedToInternet) }
            return deps
        }
        func projects() async throws -> [Project] {
            if fail { throw URLError(.notConnectedToInternet) }
            return projs
        }
    }

    final class Recorder: WidgetTimelineReloading {
        var written: [WidgetSnapshot] = []
        var reloads = 0
        func reloadAllTimelines() { reloads += 1 }
    }

    private func makeStores(suite: String = UUID().uuidString) -> (AccountStore, SettingsStore) {
        let defaults = UserDefaults(suiteName: suite)!
        let accountStore = AccountStore(defaults: defaults, credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        return (accountStore, SettingsStore(defaults: defaults))
    }

    private func publisher(_ r: Recorder) -> WidgetPublisher {
        WidgetPublisher(write: { r.written.append($0) }, reloader: r)
    }

    func test_successfulPollPublishesFollowedProjects() async {
        let (accounts, settings) = makeStores()
        _ = accounts.addKeychainAccount(provider: .vercel, label: "A", token: "t")
        let r = Recorder()
        let store = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { _, _ in StubClient(deps: [building], projs: [web]) },
            authRetryBackoff: .zero, widgetPublisher: publisher(r))

        await store.poll()

        XCTAssertEqual(r.written.last?.projects.map(\.name), ["web"])
        XCTAssertEqual(r.written.last?.projects.first?.deployments.map(\.id), ["d1"])
        XCTAssertEqual(r.reloads, 1)
    }

    func test_unfollowingRepublishesWithoutTheProject() async throws {
        let (accounts, settings) = makeStores()
        _ = accounts.addKeychainAccount(provider: .vercel, label: "A", token: "t")
        let r = Recorder()
        let store = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { _, _ in StubClient(projs: [web, api]) },
            authRetryBackoff: .zero, widgetPublisher: publisher(r))
        await store.poll()

        let sp = try XCTUnwrap(store.allSourcedProjects.first { $0.project.name == "api" })
        store.setFollowed(sp, false)

        XCTAssertEqual(r.written.last?.projects.map(\.name), ["web"])
    }

    func test_removingAccountRepublishes() async {
        let (accounts, settings) = makeStores()
        let only = accounts.addKeychainAccount(provider: .vercel, label: "A", token: "t")
        let r = Recorder()
        let store = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { _, _ in StubClient(projs: [web]) },
            authRetryBackoff: .zero, widgetPublisher: publisher(r))
        await store.poll()

        accounts.removeAccount(only)
        await store.accountsChanged()

        XCTAssertEqual(r.written.last?.projects.count, 0)
    }

    func test_failedPollDoesNotPublish() async {
        let (accounts, settings) = makeStores()
        _ = accounts.addKeychainAccount(provider: .vercel, label: "A", token: "t")
        let r = Recorder()
        let store = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { _, _ in StubClient(fail: true) },
            authRetryBackoff: .zero, widgetPublisher: publisher(r))

        await store.poll()

        XCTAssertTrue(r.written.isEmpty, "an offline tick must not replace good data or refresh generatedAt")
    }

    /// Account A stays healthy across two polls; account B's client fails on
    /// the second. A's project must show the second poll's time while B's
    /// project keeps the first poll's time — a global `generatedAt` would
    /// wrongly present B's replayed rows as just-fetched.
    func test_perProjectUpdatedAtTracksItsOwnScopesLastSuccess() async throws {
        let (accounts, settings) = makeStores()
        let accountA = accounts.addKeychainAccount(provider: .vercel, label: "A", token: "ta")
        let accountB = accounts.addKeychainAccount(provider: .vercel, label: "B", token: "tb")
        let r = Recorder()
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        var bShouldFail = false
        // A's deployment set changes between polls so the second poll's
        // snapshot is a genuine content change — WidgetPublisher itself skips
        // rewriting an unchanged snapshot inside the heartbeat window, which is
        // orthogonal to what this test checks (per-project `updatedAt`).
        let secondBuilding = Deployment(uid: "d2", name: "web", stateRaw: "READY",
                                        url: "web-2.vercel.app", createdAt: 2_000)
        var aHasNewDeploy = false
        let store = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { account, _ in
                if account.id == accountA.id {
                    return StubClient(deps: aHasNewDeploy ? [secondBuilding] : [], projs: [web])
                }
                return StubClient(projs: [api], fail: bShouldFail)
            },
            now: { clock }, authRetryBackoff: .zero, widgetPublisher: publisher(r))

        await store.poll()
        let firstPollTime = clock
        clock += 60
        bShouldFail = true
        aHasNewDeploy = true
        await store.poll()

        let projects = try XCTUnwrap(r.written.last?.projects)
        let webProject = try XCTUnwrap(projects.first { $0.name == "web" })
        let apiProject = try XCTUnwrap(projects.first { $0.name == "api" })
        XCTAssertEqual(webProject.updatedAt, clock, "A's scope was fetched successfully this tick")
        XCTAssertEqual(apiProject.updatedAt, firstPollTime,
                       "B's scope failed this tick — its rows are replayed from the first poll")
    }

    func test_restoredCacheAloneDoesNotPublish() async {
        let suite = UUID().uuidString
        let (accounts, settings) = makeStores(suite: suite)
        _ = accounts.addKeychainAccount(provider: .vercel, label: "A", token: "t")
        let first = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { _, _ in StubClient(projs: [web]) },
            authRetryBackoff: .zero)
        await first.poll()      // writes the row cache

        let (accounts2, settings2) = makeStores(suite: suite)
        let r = Recorder()
        _ = DeploymentStore(
            accountStore: accounts2, settings: settings2,
            makeClient: { _, _ in StubClient(fail: true) },
            authRetryBackoff: .zero, widgetPublisher: publisher(r))

        XCTAssertTrue(r.written.isEmpty,
                      "cached rows must not be republished as if they were just fetched")
    }
}
