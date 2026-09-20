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

    private static func deployment(uid: String, name: String) -> Deployment {
        let json = """
        {"uid":"\(uid)","name":"\(name)","state":"READY","url":"\(name).vercel.app",
         "createdAt":1}
        """
        return try! JSONDecoder().decode(Deployment.self, from: Data(json.utf8))
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
            // Every scope (account or org) that gets fetched returns one project
            // and one deployment, named after the scope, so a test can tell
            // exactly which scopes actually reached the network.
            makeClient: { _, teamId in
                let key = teamId ?? "account"
                return StubClient(deps: [Self.deployment(uid: "d_\(key)", name: "repo")],
                                  projs: [Self.project(id: "p_\(key)", name: "repo")])
            },
            reloadToken: { nil }, authRetryBackoff: .zero)
        return (store, settings)
    }

    /// Drives a real `poll()` with a stub that WOULD return a row for the
    /// disabled org's scope if it were ever fetched, and asserts that row never
    /// reaches the store. `DeploymentStore.notifier` is private, so this test
    /// can't intercept `StateTransition`s or `NotificationGate.shouldNotify`
    /// directly; it instead exercises the actual precondition for a
    /// notification: `runPoll()` only diffs and hands transitions to the
    /// notifier for scopes whose rows made it into `sourcedDeployments`. No row
    /// for the disabled scope means no snapshot for it, means no transition for
    /// it, means nothing to notify about — a disabled org is invisible to the
    /// notifier by construction, not just absent from `availableScopes`.
    func test_disabledOrganizationNeverNotifies() async {
        let (store, settings) = Self.makeStore(accounts: [Self.gitHubAccount])
        store.setOrganizations([Team(id: "Vorciu", slug: "Vorciu", name: "Vorciu")],
                               for: Self.gitHubAccount.id)
        let scopeId = ScopeRef(accountId: Self.gitHubAccount.id, teamId: "Vorciu").id
        settings.setScopeEnabled(false, for: scopeId)

        await store.poll()

        XCTAssertFalse(store.sourcedProjects.contains { $0.teamId == "Vorciu" },
                       "a disabled scope's project must never reach the store, let alone notify")
        XCTAssertFalse(store.sourcedDeployments.contains { $0.teamId == "Vorciu" },
                       "a disabled scope's deployment must never reach the store, let alone notify")
    }

    func test_reenablingAnOrganizationDropsItsStaleRows() async {
        let (store, settings) = Self.makeStore(accounts: [Self.gitHubAccount])
        store.setOrganizations([Team(id: "Vorciu", slug: "Vorciu", name: "Vorciu")],
                               for: Self.gitHubAccount.id)
        let scopeId = ScopeRef(accountId: Self.gitHubAccount.id, teamId: "Vorciu").id

        // Precondition: enabled and polled, so there is actually something to
        // drop. Asserted, not assumed.
        await store.poll()
        XCTAssertTrue(store.sourcedProjects.contains { $0.teamId == "Vorciu" },
                     "precondition failed: the org's row never made it into the store")

        settings.setScopeEnabled(false, for: scopeId)
        store.scopeEnablementChanged(accountId: Self.gitHubAccount.id, teamId: "Vorciu")

        XCTAssertFalse(store.sourcedProjects.contains { $0.teamId == "Vorciu" },
                       "disabling must remove the org's rows from the merged view")

        // Re-enable WITHOUT polling again: if the cache eviction in
        // `scopeEnablementChanged` didn't happen, a stale `lastGood` snapshot
        // would still be sitting there ready to be replayed on the next
        // `applyDisplayFilter()` — which `setScopeEnabled` alone doesn't trigger,
        // so this only proves something if `scopeEnablementChanged` actually
        // forgot the cached rows rather than merely filtering them out live.
        settings.setScopeEnabled(true, for: scopeId)

        XCTAssertFalse(store.sourcedProjects.contains { $0.teamId == "Vorciu" },
                       "re-enabling without a fresh poll must not resurrect a pre-disable snapshot")
    }
    private actor ResponseGate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait(started: XCTestExpectation) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }

    private struct DelayedClient: DeploymentProviderClient {
        let gate: ResponseGate
        let started: XCTestExpectation
        func deployments(limit: Int) async throws -> [Deployment] {
            await gate.wait(started: started)
            return [Deployment(uid: "late", name: "late", stateRaw: "ERROR", url: "", createdAt: 1)]
        }
        func projects() async throws -> [Project] { [] }
    }

    func test_scopeDisabledDuringFetchCannotRaiseAnAlert() async {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            credentials: InMemoryCredentialStore(), detectCLI: { true }, reloadCLIToken: { "t" }, detectGitHubCLI: { false })
        let account = accounts.cliAccount!
        let settings = settings()
        let gate = ResponseGate()
        let started = expectation(description: "organization request awaiting response")
        var delay = false
        let store = DeploymentStore(accountStore: accounts, settings: settings, makeClient: { _, teamId in
            if teamId != nil && delay { return DelayedClient(gate: gate, started: started) }
            return StubClient(deps: [Self.deployment(uid: teamId ?? "personal", name: "repo")], projs: [])
        })
        store.setOrganizations([Team(id: "org", slug: "org", name: "org")], for: account.id)
        await store.poll()
        store.acknowledge()
        delay = true
        let pending = Task { await store.poll() }
        await fulfillment(of: [started], timeout: 2)
        settings.setScopeEnabled(false, for: ScopeRef(accountId: account.id, teamId: "org").id)
        store.scopeEnablementChanged(accountId: account.id, teamId: "org")
        await gate.resume()
        await pending.value
        XCTAssertEqual(store.iconState, .idle, "discard stale results before notification diff")
        XCTAssertFalse(store.allSourcedProjects.contains { $0.teamId == "org" })
    }

}
