import XCTest
@testable import DeployBar

/// The owner shown before a project's name in the Projects list.
///
/// The personal scope is the subtle case: the account's *label* is this app's
/// name for the credential ("Vercel CLI"), not an organization, so showing it
/// would render "Vercel CLI/social" where Vercel itself says "username/social".
@MainActor
final class ProjectOwnerLabelTests: XCTestCase {

    private func makeStore() -> (DeploymentStore, Account) {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { true }, reloadCLIToken: { "tok" },
                                        detectGitHubCLI: { false })
        let cli = accountStore.cliAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, _ in StubOwnerClient() },
            reloadToken: { "tok" }, authRetryBackoff: .zero)
        return (store, cli)
    }

    /// A team scope is a real org — its slug is exactly what should prefix the name.
    func test_usesTheTeamSlugForATeamScope() {
        let (store, cli) = makeStore()
        store.teams = [Team(id: "team_1", slug: "foka-ventures", name: "Foka Ventures")]
        XCTAssertEqual(store.projectOwnerLabel(accountId: cli.id, teamId: "team_1"),
                       "foka-ventures")
    }

    /// The point of the method: the username, not the "Vercel CLI" account label.
    func test_usesTheVercelUsernameForThePersonalScope() {
        let (store, cli) = makeStore()
        store.user = VercelUser(username: "konrad-8lines", name: "Konrad", email: nil, avatar: nil)

        let owner = store.projectOwnerLabel(accountId: cli.id, teamId: nil)
        XCTAssertEqual(owner, "konrad-8lines")
        XCTAssertNotEqual(owner, cli.label, "The account label is not an organization")
    }

    /// The user request is a separate call that may not have landed yet; a
    /// missing username must leave the title unprefixed rather than guess.
    func test_noOwnerUntilTheUserIsKnown() {
        let (store, cli) = makeStore()
        XCTAssertNil(store.user)
        XCTAssertNil(store.projectOwnerLabel(accountId: cli.id, teamId: nil))
    }

    /// A team whose name hasn't loaded yet is nil rather than a raw "team_…" id.
    func test_noOwnerForAnUnknownTeam() {
        let (store, cli) = makeStore()
        store.teams = []
        XCTAssertNil(store.projectOwnerLabel(accountId: cli.id, teamId: "team_missing"))
    }

    func test_noOwnerForAnUnknownAccount() {
        let (store, _) = makeStore()
        XCTAssertNil(store.projectOwnerLabel(accountId: UUID(), teamId: nil))
    }
}

/// Minimal client: these tests only exercise label lookup, never a poll.
private struct StubOwnerClient: DeploymentProviderClient {
    func deployments(limit: Int) async throws -> [Deployment] { [] }
    func projects() async throws -> [Project] { [] }
    func failureReport(for deployment: Deployment) async throws -> String { "" }
}
