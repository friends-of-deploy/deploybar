import XCTest
@testable import DeployBar

@MainActor
final class DeploymentStoreTests: XCTestCase {

    private func makeStore(deploymentsData: Data, projectsData: Data = Data(#"{"projects":[]}"#.utf8)) -> DeploymentStore {
        let creds = VercelCredentials(token: "x", teamId: nil)
        let client = VercelClient(credentials: creds) { req in
            let isDeployments = req.url!.path.contains("deployments")
            let data = isDeployments ? deploymentsData : projectsData
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return DeploymentStore(client: client, settings: settings, scopeName: "test", reloadToken: { nil })
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    func test_iconStateDerivation() {
        XCTAssertEqual(DeploymentStore.iconState(for: [.ready, .building]), .building)
        XCTAssertEqual(DeploymentStore.iconState(for: [.ready, .error]), .failure)
        XCTAssertEqual(DeploymentStore.iconState(for: [.error, .building]), .failure) // failure wins
        XCTAssertEqual(DeploymentStore.iconState(for: [.ready, .ready]), .ready)
        XCTAssertEqual(DeploymentStore.iconState(for: []), .ready)
        XCTAssertEqual(DeploymentStore.iconState(for: [.queued]), .building)
    }

    func test_firstPollPopulatesAndClearsError() async throws {
        let store = makeStore(deploymentsData: try fixture("deployments"))
        await store.poll()
        XCTAssertFalse(store.deployments.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(store.lastUpdated)
    }

    func test_deploymentsSortedNewestFirst() async throws {
        let store = makeStore(deploymentsData: try fixture("deployments"))
        await store.poll()
        let times = store.deployments.map(\.createdAt)
        XCTAssertEqual(times, times.sorted(by: >))
    }

    private func alwaysUnauthorizedStore() -> DeploymentStore {
        let creds = VercelCredentials(token: "bad", teamId: nil)
        let client = VercelClient(credentials: creds) { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        return DeploymentStore(client: client, settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                               scopeName: "test", reloadToken: { nil }, authRetryBackoff: .zero)
    }

    func test_singleUnauthorizedDoesNotShowLoggedOut() async {
        // A lone 401 is treated as transient — no scary banner, no loggedOut icon.
        let store = alwaysUnauthorizedStore()
        await store.poll()
        XCTAssertNil(store.errorMessage, "a single auth blip must not surface the banner")
        XCTAssertNotEqual(store.iconState, .loggedOut)
    }

    func test_repeatedUnauthorizedEventuallyShowsLoggedOut() async {
        // A genuine logout fails every poll; after the threshold the banner shows.
        let store = alwaysUnauthorizedStore()
        for _ in 0..<5 { await store.poll() }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.errorMessage!.lowercased().contains("logged in"))
        XCTAssertEqual(store.iconState, .loggedOut)
    }

    func test_networkErrorKeepsLastDataAndSetsStale() async throws {
        // First, a good poll.
        var failNow = false
        let creds = VercelCredentials(token: "x", teamId: nil)
        let depData = try fixture("deployments")
        let client = VercelClient(credentials: creds) { req in
            if failNow { throw URLError(.notConnectedToInternet) }
            let isDeployments = req.url!.path.contains("deployments")
            let data = isDeployments ? depData : Data(#"{"projects":[]}"#.utf8)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let store = DeploymentStore(client: client, settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!), scopeName: "test", reloadToken: { nil })
        await store.poll()
        let countAfterGood = store.deployments.count
        XCTAssertGreaterThan(countAfterGood, 0)
        // Now fail.
        failNow = true
        await store.poll()
        XCTAssertEqual(store.deployments.count, countAfterGood, "keeps last-known data")
        XCTAssertNotNil(store.errorMessage, "shows stale indicator")
    }

    func test_rotatedTokenRecoversWithoutLoggedOut() async throws {
        // The CLI rotated its token: the cached "stale" token 401s, but a fresh
        // token on disk authorizes. The store must reload it and recover in-poll —
        // no banner, no loggedOut icon, even though auth.json "changed".
        let depData = try fixture("deployments")
        let staleToken = "stale", freshToken = "fresh"
        // The stubbed transport authorizes only the rotated token. Shared by the
        // initial client and any client `refreshTokenIfChanged` rebuilds, so the
        // injected transport survives a token swap.
        let fetch: VercelClient.Fetch = { req in
            let authorized = req.value(forHTTPHeaderField: "Authorization") == "Bearer \(freshToken)"
            guard authorized else {
                return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            let isDeployments = req.url!.path.contains("deployments")
            let data = isDeployments ? depData : Data(#"{"projects":[]}"#.utf8)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let store = DeploymentStore(
            client: VercelClient(credentials: VercelCredentials(token: staleToken, teamId: nil), fetch: fetch),
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            scopeName: "test",
            makeClient: { VercelClient(credentials: $0, fetch: fetch) },
            reloadToken: { freshToken },          // disk now holds the rotated token
            authRetryBackoff: .zero
        )
        await store.poll()
        XCTAssertFalse(store.deployments.isEmpty, "recovers using the rotated token")
        XCTAssertNil(store.errorMessage)
        XCTAssertNotEqual(store.iconState, .loggedOut)
    }

    func test_successfulPollClearsLoggedOutIcon() async throws {
        // Start with persistent auth failures (until the threshold trips loggedOut),
        // then recover — a good poll must clear the banner and the loggedOut icon.
        var authed = false
        let creds = VercelCredentials(token: "x", teamId: nil)
        let depData = try fixture("deployments")
        let client = VercelClient(credentials: creds) { req in
            if !authed { return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!) }
            let isDeployments = req.url!.path.contains("deployments")
            let data = isDeployments ? depData : Data(#"{"projects":[]}"#.utf8)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let store = DeploymentStore(client: client, settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                    scopeName: "test", reloadToken: { nil }, authRetryBackoff: .zero)
        for _ in 0..<5 { await store.poll() }
        XCTAssertEqual(store.iconState, .loggedOut)
        authed = true
        await store.poll()
        XCTAssertNotEqual(store.iconState, .loggedOut)
        XCTAssertNil(store.errorMessage)
    }
}
