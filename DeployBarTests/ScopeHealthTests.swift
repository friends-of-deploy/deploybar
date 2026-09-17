import XCTest
@testable import DeployBar

/// Health reporting when one account fans out into several team scopes.
///
/// `consecutiveAuthFailures` and the error map used to be keyed by account id
/// alone. Because "All" polls personal + every team of the same CLI account,
/// that key collapsed scopes that fail independently:
///   * a healthy team zeroed the shared counter every tick, so a genuinely
///     revoked team never reached `authFailureThreshold` and never reported;
///   * two teams failing in the same tick overwrote each other's message in
///     `for await` completion order, so only one survived.
/// Both are now keyed by `ScopeRef` (account + team).
@MainActor
final class ScopeHealthTests: XCTestCase {

    private struct StubClient: DeploymentProviderClient {
        var error: Error?
        func deployments(limit: Int) async throws -> [Deployment] {
            if let error { throw error }
            return []
        }
        func projects() async throws -> [Project] {
            if let error { throw error }
            return []
        }
    }

    /// A CLI account (the only source that fans out into team scopes) plus a
    /// store whose per-team client is chosen by `failingTeams`.
    private func makeStore(teams: [Team],
                           failingTeams: @escaping () -> Set<String>) -> DeploymentStore {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { true },
                                        reloadCLIToken: { "tok" },
                                        detectGitHubCLI: { false })
        let store = DeploymentStore(
            accountStore: accountStore,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { _, teamId in
                let bad = teamId.map { failingTeams().contains($0) } ?? false
                return StubClient(error: bad ? VercelClientError.unauthorized : nil)
            },
            reloadToken: { "tok" },
            authRetryBackoff: .zero
        )
        store.teams = teams
        store.setFilter(.all)
        return store
    }

    private let teams = [
        Team(id: "team_a", slug: "alpha", name: "Alpha"),
        Team(id: "team_b", slug: "bravo", name: "Bravo"),
        Team(id: "team_c", slug: "charlie", name: "Charlie"),
    ]

    /// A healthy sibling team must not mask a revoked one. Before the fix the
    /// healthy scope reset the shared counter each poll, so this never reported.
    func test_healthyTeamDoesNotMaskRevokedSibling() async {
        let store = makeStore(teams: teams, failingTeams: { ["team_b"] })

        // Well past authFailureThreshold (3).
        for _ in 0..<5 { await store.poll() }

        XCTAssertFalse(store.healthIssues.isEmpty,
                       "a permanently unauthorized team must surface even while its siblings succeed")
        XCTAssertTrue(store.healthIssues.joined().contains("bravo"),
                      "the failing team must be named, not just the account: \(store.healthIssues)")
    }

    /// Two teams failing in the same tick must both be reported — they used to
    /// overwrite each other under the shared account key.
    func test_concurrentTeamFailuresAreAllReported() async {
        let store = makeStore(teams: teams, failingTeams: { ["team_b", "team_c"] })

        for _ in 0..<5 { await store.poll() }

        let text = store.healthIssues.joined(separator: "\n")
        XCTAssertTrue(text.contains("bravo"), "bravo missing from \(text)")
        XCTAssertTrue(text.contains("charlie"), "charlie missing from \(text)")
    }

    /// Recovery still works: once the team stops failing, its message clears.
    func test_scopeErrorClearsWhenTeamRecovers() async {
        var failing: Set<String> = ["team_b"]
        let store = makeStore(teams: teams, failingTeams: { failing })

        for _ in 0..<5 { await store.poll() }
        XCTAssertFalse(store.healthIssues.isEmpty)

        failing = []
        await store.poll()
        XCTAssertTrue(store.healthIssues.isEmpty,
                      "a recovered team must clear its issue, got \(store.healthIssues)")
    }

    /// All scopes healthy → nothing to report (guards against the new per-scope
    /// key producing spurious entries).
    func test_allHealthyReportsNothing() async {
        let store = makeStore(teams: teams, failingTeams: { [] })
        await store.poll()
        XCTAssertTrue(store.healthIssues.isEmpty)
    }
}
