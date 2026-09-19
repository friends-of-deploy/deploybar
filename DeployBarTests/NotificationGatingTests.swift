import XCTest
@testable import DeployBar

@MainActor
final class NotificationGatingTests: XCTestCase {
    private func settings(failure: Bool = true, success: Bool = true,
                          started: Bool = false, canceled: Bool = false) -> SettingsStore {
        let s = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.notifyOnFailure = failure; s.notifyOnSuccess = success
        s.notifyOnStarted = started; s.notifyOnCanceled = canceled
        return s
    }
    private static let accountId = UUID()
    private func key(_ projectId: String = "p") -> ProjectKey {
        ProjectKey(provider: .vercel, accountId: Self.accountId, projectId: projectId)
    }
    private func t(_ event: DeploymentEvent, project: String = "p") -> StateTransition {
        StateTransition(uid: "1", project: project, key: key(project), event: event)
    }

    func test_failureFiresByDefault() {
        XCTAssertTrue(NotificationGate.shouldNotify(t(.failure), settings: settings()))
    }
    func test_successFiresByDefault() {
        XCTAssertTrue(NotificationGate.shouldNotify(t(.success), settings: settings()))
    }
    func test_startedSuppressedByDefault() {
        XCTAssertFalse(NotificationGate.shouldNotify(t(.started), settings: settings()))
    }
    func test_canceledSuppressedByDefault() {
        XCTAssertFalse(NotificationGate.shouldNotify(t(.canceled), settings: settings()))
    }
    func test_startedFiresWhenEnabled() {
        XCTAssertTrue(NotificationGate.shouldNotify(t(.started), settings: settings(started: true)))
    }
    func test_canceledFiresWhenEnabled() {
        XCTAssertTrue(NotificationGate.shouldNotify(t(.canceled), settings: settings(canceled: true)))
    }
    func test_failureSuppressedWhenDisabled() {
        XCTAssertFalse(NotificationGate.shouldNotify(t(.failure), settings: settings(failure: false)))
    }
    func test_perProjectOptOutBlocksEvenEnabledEvent() {
        let s = settings()
        s.setFollowed(key("p"), false)
        XCTAssertFalse(NotificationGate.shouldNotify(t(.failure, project: "p"), settings: s))
    }
    func test_perProjectOptOutDoesNotAffectOtherProjects() {
        let s = settings()
        s.setFollowed(key("other"), false)
        XCTAssertTrue(NotificationGate.shouldNotify(t(.failure, project: "p"), settings: s))
    }
    func test_mutedProjectBlocksNotificationWithoutBeingUnfollowed() {
        let s = settings()
        s.setNotificationsMuted(true, for: key("p"))

        XCTAssertTrue(s.isFollowed(key("p")))
        XCTAssertFalse(NotificationGate.shouldNotify(t(.failure, project: "p"), settings: s))
    }
    func test_mutedProjectDoesNotAffectOtherProjects() {
        let s = settings()
        s.setNotificationsMuted(true, for: key("other"))

        XCTAssertTrue(NotificationGate.shouldNotify(t(.failure, project: "p"), settings: s))
    }

    // MARK: - Disabled organizations

    private struct StubClient: DeploymentProviderClient {
        var deps: [Deployment]
        var projs: [Project]
        func deployments(limit: Int) async throws -> [Deployment] { deps }
        func projects() async throws -> [Project] { projs }
    }

    private static func project(id: String, name: String) -> Project {
        let json = """
        {"id":"\(id)","name":"\(name)"}
        """
        return try! JSONDecoder().decode(Project.self, from: Data(json.utf8))
    }

    /// A fixed GitHub CLI account so `Self.gitHubAccount.id` is stable across the
    /// calls a single test makes (building the store, then keying `ScopeRef`s).
    private static let gitHubAccount = Account.githubCLI(id: UUID(), label: "GitHub CLI")

    /// A store pre-seeded with `accounts` (persisted into its own `AccountStore`
    /// so auto-detection doesn't mint a second, unrelated account), mirroring
    /// `makeGitHubStore()` in `AllScopeTests.swift`. `DeploymentStore.settings`
    /// is private, so this hands back the same `SettingsStore` instance it wired
    /// in, letting a test reach `setScopeEnabled` directly.
    private static func makeStore(accounts: [Account]) -> (store: DeploymentStore, settings: SettingsStore) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: "connectedAccounts")
        }
        let accountStore = AccountStore(defaults: defaults,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { false }, reloadGitHubToken: { "tok" })
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, teamId in
                let key = teamId ?? "account"
                return StubClient(deps: [], projs: [Project(id: "p_\(key)", name: "repo")])
            },
            reloadToken: { nil }, authRetryBackoff: .zero)
        return (store, settings)
    }

    func test_disabledOrganizationNeverNotifies() async {
        let (store, settings) = Self.makeStore(accounts: [Self.gitHubAccount])
        store.setOrganizations([Team(id: "Vorciu", slug: "Vorciu", name: "Vorciu")],
                               for: Self.gitHubAccount.id)
        let scopeId = ScopeRef(accountId: Self.gitHubAccount.id, teamId: "Vorciu").id
        settings.setScopeEnabled(false, for: scopeId)

        // A disabled scope is not polled, so no build of its can ever be seen,
        // let alone announced.
        XCTAssertFalse(store.availableScopes.contains { $0.teamId == "Vorciu" })
    }

    func test_reenablingAnOrganizationDropsItsStaleRows() async {
        let (store, settings) = Self.makeStore(accounts: [Self.gitHubAccount])
        store.setOrganizations([Team(id: "Vorciu", slug: "Vorciu", name: "Vorciu")],
                               for: Self.gitHubAccount.id)
        let scopeId = ScopeRef(accountId: Self.gitHubAccount.id, teamId: "Vorciu").id

        settings.setScopeEnabled(false, for: scopeId)
        store.scopeEnablementChanged(accountId: Self.gitHubAccount.id, teamId: "Vorciu")
        settings.setScopeEnabled(true, for: scopeId)

        XCTAssertFalse(store.sourcedProjects.contains { $0.teamId == "Vorciu" },
                       "re-enabling must show fresh data, not a pre-disable snapshot")
    }
}
