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

    // MARK: - Organizations as scopes (GitHub)

    /// Builds a store around a GitHub CLI account (rather than the Vercel CLI
    /// account the rest of this file uses), plus the `SettingsStore` behind it
    /// so a test can reach `setScopeEnabled` directly — `DeploymentStore.settings`
    /// is private, so the store built in `makeStore(teams:)` can't expose it;
    /// this helper hands back the same instance it wired in instead.
    private func makeGitHubStore() -> (DeploymentStore, Account, SettingsStore) {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { true }, reloadGitHubToken: { "tok" })
        let github = accountStore.githubCLIAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, teamId in
                let key = teamId ?? "account"
                return StubClient(deps: [Self.deployment(uid: "d_\(key)", name: "repo")], projs: [])
            },
            reloadToken: { nil }, authRetryBackoff: .zero)
        return (store, github, settings)
    }

    func test_gitHubAccountFansOutIntoOneScopePerOrganization() async {
        let (store, github, _) = makeGitHubStore()
        store.setOrganizations([Self.team(id: "Vorciu", slug: "Vorciu"),
                                Self.team(id: "8lines", slug: "8lines")],
                               for: github.id)

        let scopes = store.scopes(for: github)

        // The account itself, then one scope per organization.
        XCTAssertEqual(scopes.map(\.teamId), [nil, "Vorciu", "8lines"])
    }

    func test_disabledOrganizationIsNotPolled() async {
        let (store, github, settings) = makeGitHubStore()
        store.setOrganizations([Self.team(id: "Vorciu", slug: "Vorciu"),
                                Self.team(id: "8lines", slug: "8lines")],
                               for: github.id)
        let disabled = ScopeRef(accountId: github.id, teamId: "8lines").id
        settings.setScopeEnabled(false, for: disabled)

        XCTAssertFalse(store.availableScopes.contains { $0.teamId == "8lines" },
                       "a disabled organization must cost no request")
        // Still selectable in Settings, so it can be switched back on.
        XCTAssertTrue(store.scopes(for: github).contains { $0.teamId == "8lines" })
    }

    func test_disablingTheAccountScopeLeavesOrganizationsPolled() async {
        let (store, github, settings) = makeGitHubStore()
        store.setOrganizations([Self.team(id: "Vorciu", slug: "Vorciu")], for: github.id)
        settings.setScopeEnabled(false, for: ScopeRef(accountId: github.id, teamId: nil).id)

        XCTAssertEqual(store.availableScopes.map(\.teamId), ["Vorciu"])
    }

    // MARK: - Poll budget (integration)

    /// Notes every teamId a client was actually built for, in call order — the
    /// only place a scope proves it was FETCHED this tick rather than replayed
    /// from `lastGood` (a replayed scope never reaches `makeClient`).
    private final class FetchRecorder {
        private(set) var fetchedTeamIds: [String?] = []
        func record(_ teamId: String?) { fetchedTeamIds.append(teamId) }
        func reset() { fetchedTeamIds = [] }
    }

    /// Builds a GitHub CLI store, like `makeGitHubStore()`, but the client
    /// factory reports every scope it is asked to build a client for into
    /// `recorder`, so a test can see exactly which scopes a given `poll()`
    /// actually fetched versus which it left to replay from `lastGood`.
    private func makeGitHubStore(recorder: FetchRecorder) -> (DeploymentStore, Account, SettingsStore) {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { true }, reloadGitHubToken: { "tok" })
        let github = accountStore.githubCLIAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, teamId in
                recorder.record(teamId)
                let key = teamId ?? "account"
                return StubClient(deps: [Self.deployment(uid: "d_\(key)", name: "repo")],
                                  projs: [Self.project(id: "p_\(key)", name: "repo")])
            },
            reloadToken: { nil }, authRetryBackoff: .zero)
        return (store, github, settings)
    }

    private static func project(id: String, name: String) -> Project {
        let json = """
        {"id":"\(id)","name":"\(name)"}
        """
        return try! JSONDecoder().decode(Project.self, from: Data(json.utf8))
    }

    /// 14 organizations + the account scope = 15 scopes. At the default 30s
    /// poll interval, GitHub's budget (5000/hr, ~6 requests/scope) affords 6
    /// scopes per tick, so a full rotation takes ceil(15/6) = 3 ticks — enough
    /// to force real rotation through `poll()`, not just the pure budget math.
    private func makeRotatingGitHubStore(recorder: FetchRecorder) -> (DeploymentStore, Account) {
        let (store, github, _) = makeGitHubStore(recorder: recorder)
        store.setOrganizations((0..<14).map { Self.team(id: "org\($0)", slug: "org\($0)") },
                               for: github.id)
        return (store, github)
    }

    /// All 15 scope ids for `makeRotatingGitHubStore`, mirroring how
    /// `scopesToPollThisTick` keys a scope.
    private func allRotatingScopeRefs(accountId: UUID) -> Set<ScopeRef> {
        Set([ScopeRef(accountId: accountId, teamId: nil)] +
            (0..<14).map { ScopeRef(accountId: accountId, teamId: "org\($0)") })
    }

    /// Rotation actually rotates: consecutive polls fetch different subsets,
    /// and every scope is fetched at least once within a full rotation.
    func test_rotationCoversEveryScopeAcrossTicks() async {
        let recorder = FetchRecorder()
        let (store, github) = makeRotatingGitHubStore(recorder: recorder)

        var fetchedPerTick: [Set<ScopeRef>] = []
        for _ in 0..<3 {
            recorder.reset()
            await store.poll()
            fetchedPerTick.append(Set(recorder.fetchedTeamIds.map {
                ScopeRef(accountId: github.id, teamId: $0)
            }))
        }

        // Each tick fetches exactly the budget (6), not every scope.
        for fetched in fetchedPerTick {
            XCTAssertEqual(fetched.count, 6, "each tick should fetch exactly the budget, not all 15 scopes")
        }
        // Consecutive ticks must not fetch the identical subset — that would
        // mean the rotation isn't advancing.
        XCTAssertNotEqual(fetchedPerTick[0], fetchedPerTick[1],
                          "the second tick must rotate onto a different subset")
        XCTAssertNotEqual(fetchedPerTick[1], fetchedPerTick[2],
                          "the third tick must rotate onto a different subset again")

        // Over a full rotation (3 ticks), every scope came round at least once.
        let everFetched = fetchedPerTick.reduce(into: Set<ScopeRef>()) { $0.formUnion($1) }
        XCTAssertEqual(everFetched, allRotatingScopeRefs(accountId: github.id),
                       "every scope must be fetched at least once within a full rotation")
    }

    /// A scope deferred to a later tick keeps showing its last-known rows
    /// instead of blinking out of the menu while it waits its turn.
    func test_deferredScopeKeepsItsRowsBetweenTicks() async {
        let recorder = FetchRecorder()
        let (store, github) = makeRotatingGitHubStore(recorder: recorder)

        await store.poll()
        let firstTickFetched = Set(recorder.fetchedTeamIds)
        // Every org scope that answered on tick 1 now has rows in the merge.
        for teamId in firstTickFetched {
            let uid = "d_\(teamId ?? "account")"
            XCTAssertTrue(store.sourcedDeployments.contains { $0.deployment.uid == uid },
                         "\(teamId ?? "account") should have rows after being fetched")
        }

        recorder.reset()
        await store.poll()
        let secondTickFetched = Set(recorder.fetchedTeamIds)

        // A scope fetched on tick 1 but NOT tick 2 was deferred this time —
        // its row must still be present, replayed from lastGood.
        let deferredThisTick = firstTickFetched.subtracting(secondTickFetched)
        XCTAssertFalse(deferredThisTick.isEmpty,
                       "the budget (6 of 15) guarantees some tick-1 scope is deferred on tick 2")
        for teamId in deferredThisTick {
            let uid = "d_\(teamId ?? "account")"
            XCTAssertTrue(store.sourcedDeployments.contains { $0.deployment.uid == uid },
                         "\(teamId ?? "account") was deferred this tick but must keep its replayed rows")
        }
    }

    /// A poll that mixes freshly-fetched scopes with replayed ones must not
    /// show any deployment or project twice — the failure mode the `polled`
    /// guard in `runPoll()` exists to prevent.
    func test_noDuplicateRowsWhenReplayingDeferredScopes() async {
        let recorder = FetchRecorder()
        let (store, _) = makeRotatingGitHubStore(recorder: recorder)

        await store.poll()
        await store.poll()   // mixes fresh (tick 2) with replayed (deferred from tick 1) scopes

        let deploymentUids = store.sourcedDeployments.map(\.deployment.uid)
        XCTAssertEqual(deploymentUids.count, Set(deploymentUids).count,
                       "no deployment should appear twice across fresh + replayed scopes")
        let projectIds = store.sourcedProjects.map(\.project.id)
        XCTAssertEqual(projectIds.count, Set(projectIds).count,
                       "no project should appear twice across fresh + replayed scopes")
    }
}
