import XCTest
@testable import DeployBar

@MainActor
final class ScopeSwitchTests: XCTestCase {

    /// Notes every teamId a client was actually built for, in call order —
    /// the only place a scope proves it was FETCHED rather than replayed from
    /// `lastGood`/the display filter. Mirrors `AllScopeTests.FetchRecorder`.
    private final class FetchRecorder {
        private(set) var fetchedTeamIds: [String?] = []
        func record(_ teamId: String?) { fetchedTeamIds.append(teamId) }
        func reset() { fetchedTeamIds = [] }
    }

    /// Not main-actor isolated (unlike `ScopeSwitchTests` itself): the
    /// `DeploymentProviderClient` protocol methods this feeds are called off
    /// the main actor, so the JSON decode has to happen right where it's used
    /// rather than through a main-actor-isolated test helper.
    private struct RecordingStubClient: DeploymentProviderClient {
        let teamId: String?
        func deployments(limit: Int) async throws -> [Deployment] {
            let uid = "d_\(teamId ?? "account")"
            let json = """
            {"uid":"\(uid)","name":"repo","state":"READY","url":"repo.vercel.app","createdAt":1}
            """
            return [try JSONDecoder().decode(Deployment.self, from: Data(json.utf8))]
        }
        func projects() async throws -> [Project] { [] }
    }

    /// Once the budgeted rotation has populated all scopes, switching display
    /// scope must reuse those rows without issuing a new fetch.
    func test_selectingAScopeRederivesRowsWithoutRefetching() async {
        let recorder = FetchRecorder()
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
                return RecordingStubClient(teamId: teamId)
            },
            now: SteppingClock().next, authRetryBackoff: .zero)
        store.setOrganizations([Self.team(id: "org_a", slug: "org_a"),
                                Self.team(id: "org_b", slug: "org_b")], for: github.id)

        // Three enabled scopes, one per default GitHub tick: allow one full
        // rotation before asserting that a display switch can reuse its rows.
        for _ in 0..<3 { await store.poll() }
        XCTAssertEqual(Set(store.sourcedDeployments.map(\.deployment.uid)),
                       ["d_account", "d_org_a", "d_org_b"])
        recorder.reset()

        await store.select(accountId: github.id, teamId: "org_b")

        XCTAssertTrue(recorder.fetchedTeamIds.isEmpty,
                      "switching scope must not trigger any new client fetch")
        XCTAssertTrue(store.sourcedDeployments.contains { $0.deployment.uid == "d_org_b" },
                     "the newly-selected scope's rows must be visible from the existing merge")
    }

    // MARK: - Menu contents

    private struct StubClient: DeploymentProviderClient {
        func deployments(limit: Int) async throws -> [Deployment] { [] }
        func projects() async throws -> [Project] { [] }
    }

    private static func team(id: String, slug: String) -> Team {
        try! JSONDecoder().decode(Team.self,
                                  from: Data(#"{"id":"\#(id)","slug":"\#(slug)","name":"\#(slug)"}"#.utf8))
    }

    /// Builds a store around a GitHub CLI account, plus the `SettingsStore`
    /// behind it — `DeploymentStore.settings` is private, so a test that
    /// needs `setScopeEnabled` has to hold onto the same instance the store
    /// was built with. Mirrors `AllScopeTests.makeGitHubStore()`.
    private func makeGitHubStore() -> (DeploymentStore, Account, SettingsStore) {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { true }, reloadGitHubToken: { "tok" })
        let github = accountStore.githubCLIAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, _ in StubClient() }, authRetryBackoff: .zero)
        return (store, github, settings)
    }

    /// Selecting a scope names it in the top bar and narrows the list to it.
    func test_selectingAScopeNamesIt() async {
        let (store, github, _) = makeGitHubStore()
        store.setOrganizations([Self.team(id: "org_b", slug: "acme")], for: github.id)

        await store.select(accountId: github.id, teamId: "org_b")

        XCTAssertEqual(store.scopeName, "acme")
        XCTAssertEqual(store.filter, .scope(accountId: github.id, teamId: "org_b"))
    }

    func test_menuHidesDisabledOrganizations() {
        let (store, github, settings) = makeGitHubStore()
        store.setOrganizations([Self.team(id: "Vorciu", slug: "Vorciu"),
                                Self.team(id: "8lines", slug: "8lines")],
                               for: github.id)
        settings.setScopeEnabled(
            false, for: ScopeRef(accountId: github.id, teamId: "8lines").id)

        let shown = PopoverView.menuScopes(for: github, store: store).map(\.teamId)

        XCTAssertEqual(shown, [nil, "Vorciu"])
    }

    func test_menuListsEveryConnectedAccountRegardlessOfProvider() {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { true }, reloadCLIToken: { "tok" },
                                        detectGitHubCLI: { true }, reloadGitHubToken: { "tok" })
        let vercel = accountStore.cliAccount!
        let github = accountStore.githubCLIAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, _ in StubClient() }, authRetryBackoff: .zero)

        XCTAssertEqual(Set(PopoverView.menuAccounts(store: store).map(\.id)),
                       Set([vercel.id, github.id]))
    }
}
