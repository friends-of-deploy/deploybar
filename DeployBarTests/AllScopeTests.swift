import XCTest
@testable import DeployBar

/// Behaviour of the "All sources" view: it must poll EVERY Vercel team (not just
/// the active one), tag rows with the scope they came from, and collapse rows a
/// project surfaces in more than one scope.
@MainActor
final class AllScopeTests: XCTestCase {

    private struct StubClient: DeploymentProviderClient {
        var deps: [Deployment]
        var projs: [Project]
        func deployments(limit: Int) async throws -> [Deployment] { deps }
        func projects() async throws -> [Project] { projs }
    }

    private static func deployment(uid: String, name: String, createdAt: Double = 1) -> Deployment {
        let json = """
        {"uid":"\(uid)","name":"\(name)","state":"READY","url":"\(name).vercel.app",
         "createdAt":\(createdAt)}
        """
        return try! JSONDecoder().decode(Deployment.self, from: Data(json.utf8))
    }

    private static func team(id: String, slug: String) -> Team {
        try! JSONDecoder().decode(Team.self,
                                  from: Data(#"{"id":"\#(id)","slug":"\#(slug)","name":"\#(slug)"}"#.utf8))
    }

    /// Builds a store whose CLI account returns a different deployment per team,
    /// so we can see exactly which scopes were polled.
    private func makeStore(teams: [Team]) -> (DeploymentStore, Account) {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { true }, reloadCLIToken: { "tok" },
                                        detectGitHubCLI: { false })
        let cli = accountStore.cliAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, teamId in
                // One deployment per scope, named after the team it came from.
                let key = teamId ?? "personal"
                return StubClient(deps: [Self.deployment(uid: "d_\(key)", name: "web")], projs: [])
            },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        store.teams = teams
        return (store, cli)
    }

    func test_allPollsEveryTeam() async {
        let (store, _) = makeStore(teams: [Self.team(id: "t1", slug: "alpha"),
                                           Self.team(id: "t2", slug: "beta")])
        XCTAssertEqual(store.filter, .all)

        await store.poll()

        // personal + both teams, not just the active scope.
        XCTAssertEqual(Set(store.sourcedDeployments.map(\.deployment.uid)),
                       ["d_personal", "d_t1", "d_t2"])
    }

    func test_rowsCarryTheTeamTheyCameFrom() async {
        let (store, _) = makeStore(teams: [Self.team(id: "t1", slug: "alpha")])
        await store.poll()

        let byUid = Dictionary(uniqueKeysWithValues: store.sourcedDeployments.map { ($0.deployment.uid, $0) })
        XCTAssertNil(byUid["d_personal"]?.teamId)
        XCTAssertEqual(byUid["d_t1"]?.teamId, "t1")
    }

    /// A single-scope selection must narrow back down to one team's rows, even
    /// though the unfiltered merge holds every team's.
    func test_selectingOneTeamNarrowsTheList() async {
        let (store, cli) = makeStore(teams: [Self.team(id: "t1", slug: "alpha"),
                                             Self.team(id: "t2", slug: "beta")])
        await store.poll()

        await store.select(accountId: cli.id, teamId: "t1")
        XCTAssertEqual(store.sourcedDeployments.map(\.deployment.uid), ["d_t1"])

        // ...and going back to All restores the full cross-team view.
        await store.selectAll()
        XCTAssertEqual(Set(store.sourcedDeployments.map(\.deployment.uid)),
                       ["d_personal", "d_t1", "d_t2"])
    }

    /// A project visible from two scopes returns the same deployment twice; the
    /// list must show it once, or the row appears duplicated.
    func test_duplicateDeploymentAcrossScopesIsCollapsed() async {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { true }, reloadCLIToken: { "tok" },
                                        detectGitHubCLI: { false })
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            // Every scope returns the SAME deployment uid.
            makeClient: { _, _ in StubClient(deps: [Self.deployment(uid: "same", name: "web")], projs: []) },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        store.teams = [Self.team(id: "t1", slug: "alpha"), Self.team(id: "t2", slug: "beta")]

        await store.poll()

        XCTAssertEqual(store.sourcedDeployments.map(\.deployment.uid), ["same"])
    }

    /// The scope marker is an "All"-only affordance — a single-scope view already
    /// names its source in the top bar.
    func test_rowScopeLabelOnlyInAll() async {
        let (store, cli) = makeStore(teams: [Self.team(id: "t1", slug: "alpha")])
        await store.poll()

        XCTAssertEqual(store.rowScopeLabel(accountId: cli.id, teamId: "t1"), "alpha")

        await store.select(accountId: cli.id, teamId: "t1")
        XCTAssertNil(store.rowScopeLabel(accountId: cli.id, teamId: "t1"))
    }
}
