import XCTest
@testable import DeployBar

/// A scope the poll budget defers keeps replaying its last-known rows. With 30
/// GitHub organizations the budget affords one scope per tick, so each one
/// refreshes only every ~15 minutes — and a run captured mid-build kept the
/// menu bar icon on "deploying" for that whole stretch after it had finished.
///
/// In-progress rows of any scope not freshly fetched this tick are now re-read
/// by id (one cheap request each), so the icon follows the real run.
@MainActor
final class InProgressRefreshTests: XCTestCase {

    /// What the provider currently reports, and which uids were re-read by id.
    private final class World: @unchecked Sendable {
        var states: [String: String] = [:]
        var refreshedUids: [String] = []
        var refreshFails = false
    }

    private struct StubClient: DeploymentProviderClient {
        let world: World
        let key: String
        func deployments(limit: Int) async throws -> [Deployment] {
            [Self.deployment(uid: "d_\(key)", state: world.states["d_\(key)"] ?? "READY")]
        }
        func projects() async throws -> [Project] { [] }
        func refreshed(_ deployments: [Deployment]) async throws -> [Deployment] {
            world.refreshedUids.append(contentsOf: deployments.map(\.uid))
            if world.refreshFails { throw ProviderClientError.http(500) }
            return deployments.map { Self.deployment(uid: $0.uid, state: world.states[$0.uid] ?? "READY") }
        }
        static func deployment(uid: String, state: String) -> Deployment {
            Deployment(uid: uid, name: "repo", stateRaw: state, url: "", createdAt: 1)
        }
    }

    private static func team(_ id: String) -> Team {
        try! JSONDecoder().decode(Team.self, from: Data(#"{"id":"\#(id)","slug":"\#(id)","name":"\#(id)"}"#.utf8))
    }

    /// 14 organizations + the account = 15 GitHub scopes, one fetched per tick.
    /// `org5` was mid-build when the app last cached its rows.
    private func makeStore(world: World) -> DeploymentStore {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { false }, reloadCLIToken: { nil },
                                    detectGitHubCLI: { true }, reloadGitHubToken: { "tok" })
        let account = accounts.githubCLIAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.cachedOrgs = [account.id: (0..<14).map { Self.team("org\($0)") }]
        settings.cachedRows = RowCache(deployments: (0..<14).map { index in
            SourcedDeployment(deployment: StubClient.deployment(uid: "d_org\(index)",
                                                                state: index == 5 ? "BUILDING" : "READY"),
                              account: account, teamId: "org\(index)")
        }, projects: [], savedAt: Date())
        return DeploymentStore(accountStore: accounts, settings: settings,
                               makeClient: { _, teamId in StubClient(world: world, key: teamId ?? "account") },
                               reloadToken: { nil }, authRetryBackoff: .zero)
    }

    private func state(of uid: String, in store: DeploymentStore) -> DeploymentState? {
        store.sourcedDeployments.first { $0.deployment.uid == uid }?.deployment.state
    }

    func test_finishedRunInDeferredScopeClearsTheBuildingIcon() async {
        let world = World()
        let store = makeStore(world: world)
        XCTAssertEqual(store.iconState, .building, "precondition: the cached run is mid-build")

        world.states["d_org5"] = "READY"      // it finished while we weren't looking
        await store.poll()                     // this tick's budget goes to another scope

        XCTAssertEqual(state(of: "d_org5", in: store), .ready)
        XCTAssertNotEqual(store.iconState, .building,
                          "a finished run must not keep the icon on deploying until its scope comes round")
    }

    func test_stillRunningDeploymentStaysBuilding() async {
        let world = World()
        world.states["d_org5"] = "BUILDING"
        let store = makeStore(world: world)

        await store.poll()

        XCTAssertEqual(store.iconState, .building)
    }

    func test_onlyInProgressRowsAreReRead() async {
        let world = World()
        let store = makeStore(world: world)

        await store.poll()

        XCTAssertEqual(world.refreshedUids, ["d_org5"],
                       "finished rows cost nothing; only the live one is re-read")
    }

    func test_failedReReadKeepsTheLastKnownRow() async {
        let world = World()
        world.refreshFails = true
        let store = makeStore(world: world)

        await store.poll()

        XCTAssertEqual(state(of: "d_org5", in: store), .building,
                       "a failed re-read must not blank or guess the row")
    }

    private static func project(_ id: String) -> Project {
        try! JSONDecoder().decode(Project.self, from: Data(#"{"id":"\#(id)","name":"repo"}"#.utf8))
    }

    /// 25 one-repository organizations, the first `building` of them mid-run
    /// when the app last cached its rows.
    private func makeSmallOrgStore(building: Int) -> DeploymentStore {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { false }, reloadCLIToken: { nil },
                                    detectGitHubCLI: { true }, reloadGitHubToken: { "tok" })
        let account = accounts.githubCLIAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let orgs = (0..<25).map { "org\($0)" }
        settings.cachedOrgs = [account.id: orgs.map(Self.team)]
        settings.cachedRows = RowCache(
            deployments: orgs.enumerated().map { index, org in
                SourcedDeployment(deployment: StubClient.deployment(uid: "d_\(org)",
                                                                    state: index < building ? "BUILDING" : "READY"),
                                  account: account, teamId: org)
            },
            projects: orgs.map { SourcedProject(project: Self.project("p_\($0)"), account: account, teamId: $0) },
            savedAt: Date())
        let world = World()
        return DeploymentStore(accountStore: accounts, settings: settings,
                               makeClient: { _, teamId in StubClient(world: world, key: teamId ?? "account") },
                               reloadToken: { nil }, authRetryBackoff: .zero)
    }

    /// Every in-progress run is re-read each tick, one request apiece, so those
    /// requests come out of the tick before any scope is scheduled.
    func test_inProgressReReadsComeOutOfTheTickBudget() {
        let quiet = makeSmallOrgStore(building: 0)
        let busy = makeSmallOrgStore(building: 10)

        // 41 requests a tick, less the 10-page listing: 31, or 21 with ten re-reads.
        XCTAssertEqual(quiet.effectiveRefreshInterval(for: quiet.connectedAccounts[0]), 60)
        XCTAssertEqual(busy.effectiveRefreshInterval(for: busy.connectedAccounts[0]), 90,
                       "ten runs re-read every tick leave room for fewer scope fetches")
    }
}
