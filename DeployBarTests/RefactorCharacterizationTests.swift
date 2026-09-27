import XCTest
@testable import DeployBar

/// Pins behaviour the provider-integration refactor must not change, written
/// against the code before it. Budget numbers move into `PollCostModel` and
/// `PollPlanner`; follow aliases move into `CredentialStrategy`.
@MainActor
final class RefactorCharacterizationTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private(set) var fetched: [ScopeRef] = []
        func record(_ ref: ScopeRef) { fetched.append(ref) }
        func reset() { fetched = [] }
    }

    /// One READY deployment and one project per scope, so a scope's size is
    /// known (one repository) after its first fetch.
    private struct StubClient: DeploymentProviderClient {
        let key: String
        func deployments(limit: Int) async throws -> [Deployment] {
            [Deployment(uid: "d_\(key)", name: "p_\(key)", stateRaw: "READY",
                        url: "x.vercel.app", createdAt: 1)]
        }
        func projects() async throws -> [Project] {
            [Project(id: "p_\(key)", name: "p_\(key)")]
        }
    }

    /// Vercel: 3 scopes at 2 requests each fit every 30 s tick (share 166).
    /// GitHub: share 41, less the 10-request listing reserve, leaves 31. The
    /// account scope costs 40, an organization 20 until its size is known,
    /// then 1. Rotation starts one past the account scope.
    func test_mixedAccountsRotateExactlyAsBeforeTheRefactor() async {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { false }, reloadCLIToken: { nil },
                                    detectGitHubCLI: { false })
        let vercel = accounts.addKeychainAccount(provider: .vercel, label: "V", token: "v-tok")
        let github = accounts.addKeychainAccount(provider: .github, label: "G", token: "g-tok")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.pollIntervalSeconds = 30
        let recorder = Recorder()
        let store = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { account, teamId in
                recorder.record(ScopeRef(accountId: account.id, teamId: teamId))
                return StubClient(key: "\(account.label)-\(teamId ?? "account")")
            },
            now: SteppingClock().next, authRetryBackoff: .zero)
        store.setOrganizations([Team(id: "t1", slug: "t1", name: "t1"),
                                Team(id: "t2", slug: "t2", name: "t2")], for: vercel.id)
        store.setOrganizations([Team(id: "o1", slug: "o1", name: "o1"),
                                Team(id: "o2", slug: "o2", name: "o2")], for: github.id)

        let expectedGitHub: [Set<String?>] = [["o1"], ["o2"], [nil], ["o1", "o2"], [nil]]
        for (tick, expected) in expectedGitHub.enumerated() {
            recorder.reset()
            await store.poll()
            let v = Set(recorder.fetched.filter { $0.accountId == vercel.id }.map(\.teamId))
            let g = Set(recorder.fetched.filter { $0.accountId == github.id }.map(\.teamId))
            XCTAssertEqual(v, [nil, "t1", "t2"], "tick \(tick + 1): every Vercel scope, every tick")
            XCTAssertEqual(g, expected, "tick \(tick + 1)")
        }
        XCTAssertEqual(store.effectiveRefreshInterval(for: vercel), 30)
        XCTAssertEqual(store.effectiveRefreshInterval(for: github), 60,
                       "the account scope on one tick, both one-repo organizations on the next")
    }

    /// Mutes stored by project name before follow keys used ids are still
    /// honoured, for the Vercel CLI account only.
    func test_cliProjectMutedByNameStaysHidden() async throws {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { true }, reloadCLIToken: { "tok" },
                                    detectGitHubCLI: { false })
        let cli = accounts.cliAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.setFollowed(ProjectKey(provider: .vercel, accountId: cli.id, projectId: "web"), false)
        let store = DeploymentStore(
            accountStore: accounts, settings: settings,
            makeClient: { _, _ in NamedProjectClient() }, authRetryBackoff: .zero)

        await store.poll()

        XCTAssertTrue(store.sourcedProjects.isEmpty, "the name-keyed mute hides the project")
        let project = try XCTUnwrap(store.allSourcedProjects.first)
        store.setFollowed(project, true)
        XCTAssertTrue(store.isFollowed(project), "following again clears the name key too")
    }

    private struct NamedProjectClient: DeploymentProviderClient {
        func deployments(limit: Int) async throws -> [Deployment] { [] }
        func projects() async throws -> [Project] { [Project(id: "prj_1", name: "web")] }
    }
}
