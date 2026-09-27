import XCTest
@testable import DeployBar

@MainActor
final class DeploymentStoreTests: XCTestCase {

    /// One token-added Vercel account whose client is served by `fetch`.
    private func makeStore(fetch: @escaping VercelClient.Fetch) -> DeploymentStore {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { false }, detectGitHubCLI: { false })
        _ = accounts.addKeychainAccount(provider: .vercel, label: "test", token: "x")
        return DeploymentStore(
            accountStore: accounts,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { _, teamId in
                VercelClient(credentials: VercelCredentials(token: "x", teamId: teamId), fetch: fetch)
            }, authRetryBackoff: .zero)
    }

    private func makeStore(deploymentsData: Data,
                           projectsData: Data = Data(#"{"projects":[]}"#.utf8)) -> DeploymentStore {
        makeStore { req in
            let data = req.url!.path.contains("deployments") ? deploymentsData : projectsData
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    func test_iconStateDerivation() {
        XCTAssertEqual(DeploymentStore.baseState(for: [.ready, .building]), .building)
        XCTAssertEqual(DeploymentStore.baseState(for: [.ready, .error]), .failure)
        XCTAssertEqual(DeploymentStore.baseState(for: [.error, .building]), .building) // running wins
        XCTAssertEqual(DeploymentStore.baseState(for: [.ready, .ready]), .success)
        XCTAssertEqual(DeploymentStore.baseState(for: [.canceled]), .idle)
        XCTAssertEqual(DeploymentStore.baseState(for: []), .idle)
    }

    /// Only a build that is actually running lights "deploying". A queued run —
    /// including a GitHub run waiting days for environment approval — does not.
    func test_queuedRunDoesNotLightTheDeployingIcon() {
        XCTAssertEqual(DeploymentStore.baseState(for: [.queued]), .idle)
        XCTAssertEqual(DeploymentStore.baseState(for: [.queued, .ready]), .success)
        XCTAssertEqual(DeploymentStore.baseState(for: [.queued, .error]), .failure)
        XCTAssertEqual(DeploymentStore.baseState(for: [.queued, .building]), .building)
    }

    func test_firstPollPopulatesAndClearsError() async throws {
        let store = makeStore(deploymentsData: try fixture("deployments"))
        await store.poll()
        XCTAssertFalse(store.deployments.isEmpty)
        XCTAssertTrue(store.healthIssues.isEmpty)
        XCTAssertNotNil(store.lastUpdated)
    }

    func test_deploymentsSortedNewestFirst() async throws {
        let store = makeStore(deploymentsData: try fixture("deployments"))
        await store.poll()
        let times = store.deployments.map(\.createdAt)
        XCTAssertEqual(times, times.sorted(by: >))
    }

    private func alwaysUnauthorizedStore() -> DeploymentStore {
        makeStore { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
    }

    func test_singleUnauthorizedDoesNotShowLoggedOut() async {
        // A lone 401 is treated as transient — no scary banner, no loggedOut icon.
        let store = alwaysUnauthorizedStore()
        await store.poll()
        XCTAssertTrue(store.healthIssues.isEmpty, "a single auth blip must not surface an issue")
        XCTAssertNotEqual(store.iconState, .loggedOut)
    }

    func test_repeatedUnauthorizedEventuallyShowsLoggedOut() async {
        // A genuine logout fails every poll; after the threshold the banner shows.
        let store = alwaysUnauthorizedStore()
        for _ in 0..<5 { await store.poll() }
        XCTAssertFalse(store.healthIssues.isEmpty)
        XCTAssertTrue(store.healthIssues.contains { $0.lowercased().contains("logged in") })
        XCTAssertEqual(store.iconState, .loggedOut)
    }

    func test_networkErrorKeepsLastDataAndSetsStale() async throws {
        var failNow = false
        let depData = try fixture("deployments")
        let store = makeStore { req in
            if failNow { throw URLError(.notConnectedToInternet) }
            let data = req.url!.path.contains("deployments") ? depData : Data(#"{"projects":[]}"#.utf8)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await store.poll()
        let countAfterGood = store.deployments.count
        XCTAssertGreaterThan(countAfterGood, 0)
        failNow = true
        await store.poll()
        XCTAssertEqual(store.deployments.count, countAfterGood, "keeps last-known data")
        XCTAssertFalse(store.healthIssues.isEmpty, "shows stale indicator")
    }

    // MARK: - Vercel CLI token rotation

    /// Stands in for `auth.json`: the Vercel CLI rewrites it between requests.
    private final class Disk: @unchecked Sendable {
        var token: String
        init(_ token: String) { self.token = token }
    }

    private final class Counter: @unchecked Sendable {
        var clientsBuilt = 0
        var deploymentCalls = 0
    }

    /// Authorizes only the "fresh" token. When `rotatesOnFailure`, a rejected
    /// request makes the CLI rotate its token on disk, as a real expiry does.
    private struct TokenClient: DeploymentProviderClient {
        let token: String
        let key: String
        let disk: Disk
        let counter: Counter
        let rotatesOnFailure: Bool
        func deployments(limit: Int) async throws -> [Deployment] {
            counter.deploymentCalls += 1
            guard token == "fresh" else {
                if rotatesOnFailure { disk.token = "fresh" }
                throw ProviderClientError.unauthorized
            }
            return [Deployment(uid: "d_\(key)", name: "web", stateRaw: "READY",
                               url: "web.vercel.app", createdAt: 1)]
        }
        func projects() async throws -> [Project] { [] }
    }

    private func makeCLIStore(disk: Disk, counter: Counter, rotatesOnFailure: Bool) -> DeploymentStore {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { true }, reloadCLIToken: { disk.token },
                                    detectGitHubCLI: { false })
        return DeploymentStore(
            accountStore: accounts,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { account, teamId in
                counter.clientsBuilt += 1
                return TokenClient(token: accounts.token(for: account) ?? "", key: teamId ?? "personal",
                                   disk: disk, counter: counter, rotatesOnFailure: rotatesOnFailure)
            }, authRetryBackoff: .zero)
    }

    func test_rotatedCLITokenRebuildsTheClientAndRecovers() async {
        let disk = Disk("stale"), counter = Counter()
        let store = makeCLIStore(disk: disk, counter: counter, rotatesOnFailure: true)
        await store.poll()
        XCTAssertEqual(store.deployments.map(\.uid), ["d_personal"], "recovers using the rotated token")
        XCTAssertTrue(store.healthIssues.isEmpty)
        XCTAssertNotEqual(store.iconState, .loggedOut)
        XCTAssertEqual(counter.clientsBuilt, 2, "a rotated token gets a fresh client")
    }

    func test_unchangedCLITokenRetriesTheSameClientOnce() async {
        let disk = Disk("stale"), counter = Counter()
        let store = makeCLIStore(disk: disk, counter: counter, rotatesOnFailure: false)
        await store.poll()
        XCTAssertTrue(store.deployments.isEmpty)
        XCTAssertEqual(counter.clientsBuilt, 1, "no rotation: the same client is retried")
        XCTAssertEqual(counter.deploymentCalls, 2, "exactly one retry")
    }

    func test_successfulPollClearsLoggedOutIcon() async throws {
        var authed = false
        let depData = try fixture("deployments")
        let store = makeStore { req in
            if !authed { return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!) }
            let data = req.url!.path.contains("deployments") ? depData : Data(#"{"projects":[]}"#.utf8)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        for _ in 0..<5 { await store.poll() }
        XCTAssertEqual(store.iconState, .loggedOut)
        authed = true
        await store.poll()
        XCTAssertNotEqual(store.iconState, .loggedOut)
        XCTAssertTrue(store.healthIssues.isEmpty)
    }

    // MARK: - Health dot (replaces the bottom status bar)

    func test_healthIssuesEmptyOnGoodPoll() async throws {
        let store = makeStore(deploymentsData: try fixture("deployments"))
        await store.poll()
        XCTAssertTrue(store.healthIssues.isEmpty, "a healthy poll has nothing to report")
    }

    func test_healthIssuesReportLogoutAfterRepeatedUnauthorized() async {
        let store = alwaysUnauthorizedStore()
        for _ in 0..<5 { await store.poll() }
        XCTAssertFalse(store.healthIssues.isEmpty)
        XCTAssertTrue(store.healthIssues.contains { $0.lowercased().contains("logged in") })
    }

    func test_healthIssuesReportStaleSource() async throws {
        var failNow = false
        let depData = try fixture("deployments")
        let store = makeStore { req in
            if failNow { throw URLError(.notConnectedToInternet) }
            return (req.url!.path.contains("deployments") ? depData : Data(#"{"projects":[]}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await store.poll()
        XCTAssertTrue(store.healthIssues.isEmpty)
        failNow = true
        await store.poll()
        XCTAssertFalse(store.healthIssues.isEmpty, "a failed source is listed on the dot")
    }

    /// One line per failing source — the dot's tooltip lists them all, where the
    /// old status bar could only show the first.
    func test_healthIssuesAreStableAcrossPolls() async throws {
        var failNow = false
        let depData = try fixture("deployments")
        let store = makeStore { req in
            if failNow { throw URLError(.notConnectedToInternet) }
            return (req.url!.path.contains("deployments") ? depData : Data(#"{"projects":[]}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await store.poll()
        failNow = true
        await store.poll()
        let first = store.healthIssues
        await store.poll()
        XCTAssertEqual(first, store.healthIssues, "the list must not reshuffle between polls")
    }

    func test_isRefreshingIsFalseOncePollSettles() async throws {
        let store = makeStore(deploymentsData: try fixture("deployments"))
        XCTAssertFalse(store.isRefreshing, "idle before the first poll")
        await store.poll()
        XCTAssertFalse(store.isRefreshing, "cleared once the poll finishes")
    }
}
