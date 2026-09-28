import XCTest
@testable import DeployBar

@MainActor
final class OrganizationDiscoveryTests: XCTestCase {

    private final class Discovery: @unchecked Sendable {
        var calls = 0
        var answer: Result<[Team], Error> = .failure(URLError(.notConnectedToInternet))
    }

    private struct StubClient: DeploymentProviderClient {
        let key: String
        func deployments(limit: Int) async throws -> [Deployment] {
            [Deployment(uid: "d_\(key)", name: "p/\(key)", stateRaw: "READY", url: "", createdAt: 1)]
        }
        func projects() async throws -> [Project] { [] }
    }

    /// Organizations only: no account-level scope, like Azure DevOps.
    private struct OrgsOnlyIntegration: ProviderIntegration {
        let discovery: Discovery
        var provider: Provider { .azureDevOps }
        var hasAccountScope: Bool { false }
        var pollCost: PollCostModel { GitHubIntegration().pollCost }
        var presentation: ProviderPresentation { GitHubIntegration().presentation }
        func identity(for account: Account, using credential: ResolvedCredential) async throws -> AccountIdentity {
            throw URLError(.userAuthenticationRequired)
        }
        func organizations(for account: Account, using credential: ResolvedCredential) async throws -> [Team] {
            discovery.calls += 1
            return try discovery.answer.get()
        }
        @MainActor func client(for scope: Scope, using credential: ResolvedCredential) -> DeploymentProviderClient? {
            scope.teamId.map { StubClient(key: $0) }
        }
        func failureReport(for deployment: Deployment, teamId: String?, using credential: ResolvedCredential) async throws -> String { "" }
    }

    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeStore(_ discovery: Discovery, alsoGitHub: Bool = false,
                           credentials: InMemoryCredentialStore = InMemoryCredentialStore()) -> (DeploymentStore, AccountStore) {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: credentials,
                                    detectCLI: { false }, detectGitHubCLI: { false })
        _ = accounts.addKeychainAccount(provider: .azureDevOps, label: "ADO", token: "pat")
        var integrations: [any ProviderIntegration] = [OrgsOnlyIntegration(discovery: discovery)]
        if alsoGitHub {
            _ = accounts.addKeychainAccount(provider: .github, label: "GH", token: "gh")
            integrations.append(OverridingIntegration(base: GitHubIntegration(),
                                                      makeClient: { _, _ in StubClient(key: "gh") },
                                                      discoveryFetch: nil, clientFetch: nil))
        }
        let store = DeploymentStore(accountStore: accounts,
                                    settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                    registry: ProviderRegistry(integrations),
                                    now: { [unowned self] in self.clock },
                                    authRetryBackoff: .zero)
        return (store, accounts)
    }

    func test_failedDiscoveryIsReportedNotALogout() async {
        let discovery = Discovery()
        let (store, _) = makeStore(discovery)
        await store.poll()
        XCTAssertNotEqual(store.iconState, .loggedOut)
        XCTAssertEqual(store.healthIssues, ["ADO: couldn’t load organizations — retrying"])
    }

    func test_tokenThatSeesNoOrganizationSaysSo() async {
        let discovery = Discovery()
        discovery.answer = .success([])
        let (store, _) = makeStore(discovery)
        await store.poll()
        XCTAssertNotEqual(store.iconState, .loggedOut)
        XCTAssertEqual(store.healthIssues, ["ADO: this token can’t see any organization"])
    }

    func test_discoveryRetriesAtMostEveryFiveMinutes() async {
        let discovery = Discovery()
        let (store, _) = makeStore(discovery)
        await store.poll()
        XCTAssertEqual(discovery.calls, 1)
        clock.addTimeInterval(60)
        await store.poll()
        XCTAssertEqual(discovery.calls, 1, "a minute later: no retry")
        clock.addTimeInterval(DeploymentStore.discoveryRetryInterval)
        await store.poll()
        XCTAssertEqual(discovery.calls, 2)
    }

    func test_discoveredOrganizationsJoinTheRotation() async {
        let discovery = Discovery()
        let (store, accounts) = makeStore(discovery)
        await store.poll()
        discovery.answer = .success([Team(id: "contoso", slug: "contoso", name: "contoso")])
        clock.addTimeInterval(DeploymentStore.discoveryRetryInterval + 1)
        await store.poll()
        XCTAssertEqual(store.scopes(for: accounts.accounts[0]).map(\.teamId), ["contoso"])
        XCTAssertEqual(store.deployments.map(\.uid), ["d_contoso"])
        XCTAssertTrue(store.healthIssues.isEmpty)
    }

    /// A waiting account's discovery issue must not read as a whole-app logout.
    func test_waitingAccountDoesNotLogOutOthers() async {
        let discovery = Discovery()
        let (store, _) = makeStore(discovery, alsoGitHub: true)
        await store.poll()
        XCTAssertNotEqual(store.iconState, .loggedOut)
        XCTAssertTrue(store.deployments.contains { $0.uid == "d_gh" })
        XCTAssertEqual(store.healthIssues, ["ADO: couldn’t load organizations — retrying"])
    }

    func test_removedAccountForgetsItsDiscoveryState() async {
        let discovery = Discovery()
        let (store, accounts) = makeStore(discovery)
        await store.poll()
        accounts.removeAccount(accounts.accounts[0])
        await store.accountsChanged()
        XCTAssertTrue(store.discoveryIssues.isEmpty)
    }

    /// An orgs-only account with no resolvable credential (keychain token
    /// missing) can't even attempt discovery: `awaitsOrganizations` must not
    /// treat it as "still connected, just waiting", or the app would look
    /// healthy while nothing works. Before this task, that account alone gave
    /// the logged-out state, and this preserves it.
    func test_accountWithoutACredentialIsALogout() async {
        let credentials = InMemoryCredentialStore()
        let discovery = Discovery()
        let (store, accounts) = makeStore(discovery, credentials: credentials)
        if case .keychain(let name) = accounts.accounts[0].source { credentials.removeToken(for: name) }

        await store.poll()

        XCTAssertEqual(store.iconState, .loggedOut)
        XCTAssertEqual(discovery.calls, 0, "no credential: discovery is never attempted")
    }
}
