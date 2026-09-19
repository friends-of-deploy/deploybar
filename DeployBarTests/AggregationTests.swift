import XCTest
@testable import DeployBar

@MainActor
final class AggregationTests: XCTestCase {
    func test_snapshotCarriesProjectKey() {
        let key = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "p")
        let snap = DeploymentSnapshot(uid: "u1", name: "web", state: .building, key: key)
        XCTAssertEqual(snap.key, key)
    }
}

// MARK: - Fixtures + stub client

/// A canned provider client returning fixed deployments/projects, or throwing.
private struct StubClient: DeploymentProviderClient {
    var deps: [Deployment]
    var projs: [Project]
    var error: Error?

    func deployments(limit: Int) async throws -> [Deployment] {
        if let error { throw error }
        return deps
    }
    func projects() async throws -> [Project] {
        if let error { throw error }
        return projs
    }
}

private enum Fixtures {
    static func deployment(uid: String, name: String, state: String = "READY",
                           createdAt: Double = 1) -> Deployment {
        let json = """
        {"uid":"\(uid)","name":"\(name)","state":"\(state)","url":"\(name).vercel.app",
         "createdAt":\(createdAt)}
        """
        return try! JSONDecoder().decode(Deployment.self, from: Data(json.utf8))
    }
    static func project(id: String, name: String) -> Project {
        let json = """
        {"id":"\(id)","name":"\(name)"}
        """
        return try! JSONDecoder().decode(Project.self, from: Data(json.utf8))
    }
}

extension AggregationTests {
    /// Builds an AccountStore with two keychain Vercel accounts (no CLI account).
    private func makeAccountStore() -> (store: AccountStore, a: Account, b: Account) {
        let store = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                 credentials: InMemoryCredentialStore(),
                                 detectCLI: { false },
                                 reloadCLIToken: { nil },
                                 detectGitHubCLI: { false })
        let a = store.addKeychainAccount(provider: .vercel, label: "Acct A", token: "tok-a")
        let b = store.addKeychainAccount(provider: .vercel, label: "Acct B", token: "tok-b")
        return (store, a, b)
    }

    func test_aggregatesAndFiltersAcrossAccounts() async {
        let (accountStore, a, b) = makeAccountStore()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        // Per-account canned data. Account A throws when `failA` flips true.
        var failA = false
        let depA = Fixtures.deployment(uid: "da", name: "alpha", createdAt: 2)
        let projA = Fixtures.project(id: "pa", name: "alpha")
        let depB = Fixtures.deployment(uid: "db", name: "beta", createdAt: 1)
        let projB = Fixtures.project(id: "pb", name: "beta")

        let store = DeploymentStore(
            accountStore: accountStore,
            settings: settings,
            makeClient: { account, _ in
                if account.id == a.id {
                    return StubClient(deps: [depA], projs: [projA],
                                      error: failA ? VercelClientError.http(500) : nil)
                } else {
                    return StubClient(deps: [depB], projs: [projB], error: nil)
                }
            },
            reloadToken: { nil },
            authRetryBackoff: .zero
        )

        // 1) Merge: both accounts' projects appear.
        await store.poll()
        XCTAssertEqual(Set(store.sourcedProjects.map(\.project.id)), ["pa", "pb"])
        XCTAssertEqual(Set(store.sourcedDeployments.map(\.deployment.uid)), ["da", "db"])
        // Newest first across sources.
        XCTAssertEqual(store.sourcedDeployments.map(\.deployment.uid), ["da", "db"])

        // 2) Unfollow account A's project → it drops out.
        let keyA = ProjectKey(provider: .vercel, accountId: a.id, projectId: "pa")
        settings.setFollowed(keyA, false)
        await store.poll()
        XCTAssertEqual(Set(store.sourcedProjects.map(\.project.id)), ["pb"])
        XCTAssertFalse(store.sourcedDeployments.contains { $0.deployment.uid == "da" })

        // Re-follow for the next checks.
        settings.setFollowed(keyA, true)

        // 3) Filter to account B only.
        store.setFilter(.account(b.id))
        await store.poll()
        XCTAssertEqual(Set(store.sourcedProjects.map(\.account.id)), [b.id])
        XCTAssertEqual(store.sourcedDeployments.map(\.deployment.uid), ["db"])

        // 4) Account A's client throws → its error recorded, B's rows still present.
        store.setFilter(.all)
        failA = true
        await store.poll()
        XCTAssertNotNil(store.sourceErrors[a.id])
        XCTAssertTrue(store.sourcedProjects.contains { $0.account.id == b.id })
        XCTAssertTrue(store.sourcedDeployments.contains { $0.deployment.uid == "db" })
    }

    /// Directive 4: the CLI-only legacy name-keyed mute. A NAME-keyed unfollow must
    /// exclude the CLI project even though the id-keyed entry was never set — and it
    /// must NOT leak to a keychain account whose project id/name match those values.
    func test_cliLegacyNameFallback_mutesCLIButNotKeychain() async {
        // AccountStore creates a `.vercelCLI` account when detectCLI is true.
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { true },
                                        reloadCLIToken: { "cli-token" },
                                        detectGitHubCLI: { false })
        let cli = accountStore.cliAccount!
        let kc = accountStore.addKeychainAccount(provider: .vercel, label: "Acct KC", token: "tok-kc")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        // CLI project: id ("cli-proj-id") DIFFERS from name ("cliweb").
        let cliDep = Fixtures.deployment(uid: "cd", name: "cliweb", createdAt: 2)
        let cliProj = Fixtures.project(id: "cli-proj-id", name: "cliweb")
        // Keychain project: id == name == "cliweb" (matches the muted NAME value).
        let kcDep = Fixtures.deployment(uid: "kd", name: "cliweb", createdAt: 1)
        let kcProj = Fixtures.project(id: "cliweb", name: "cliweb")

        let store = DeploymentStore(
            accountStore: accountStore,
            settings: settings,
            makeClient: { account, _ in
                if account.source == .vercelCLI {
                    return StubClient(deps: [cliDep], projs: [cliProj], error: nil)
                } else {
                    return StubClient(deps: [kcDep], projs: [kcProj], error: nil)
                }
            },
            reloadToken: { "cli-token" },
            authRetryBackoff: .zero
        )

        // Sanity: both projects show before any mute.
        await store.poll()
        XCTAssertTrue(store.sourcedProjects.contains { $0.account.id == cli.id })
        XCTAssertTrue(store.sourcedProjects.contains { $0.account.id == kc.id })

        // NAME-keyed unfollow under the CLI account id (the id-keyed entry is never set).
        let nameKey = ProjectKey(provider: .vercel, accountId: cli.id, projectId: "cliweb")
        settings.setFollowed(nameKey, false)
        await store.poll()

        // (a) CLI branch: name fallback excludes the CLI project + its deployment.
        XCTAssertFalse(store.sourcedProjects.contains { $0.account.id == cli.id },
                       "CLI project muted by its NAME-keyed legacy key")
        XCTAssertFalse(store.sourcedDeployments.contains { $0.account.id == cli.id },
                       "CLI deployment muted by its NAME-keyed legacy key")

        // (b) Keychain early-return: the name-keyed mute does NOT leak to the
        // keychain account even though its project id/name == "cliweb".
        XCTAssertTrue(store.sourcedProjects.contains { $0.account.id == kc.id },
                      "keychain project unaffected by the CLI name fallback")
        XCTAssertTrue(store.sourcedDeployments.contains { $0.account.id == kc.id },
                      "keychain deployment unaffected by the CLI name fallback")
    }
}

// MARK: - Icon alert acknowledgment + provider split

extension AggregationTests {
    private func singleDeploymentStore(_ dep: Deployment, provider: Provider = .vercel)
        -> (DeploymentStore, AccountStore) {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        let acct = accountStore.addKeychainAccount(provider: provider, label: "A", token: "t")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { account, _ in
                account.id == acct.id ? StubClient(deps: [dep], projs: [], error: nil) : nil
            },
            reloadToken: { nil }, authRetryBackoff: .zero)
        return (store, accountStore)
    }

    func test_iconFailureAlertClearsOnAcknowledge() async {
        let (store, _) = singleDeploymentStore(
            Fixtures.deployment(uid: "e1", name: "alpha", state: "ERROR"))
        await store.poll()
        XCTAssertEqual(store.iconState, .failure)   // unacknowledged failure → red
        store.acknowledge()
        XCTAssertEqual(store.iconState, .idle)       // cleared on open
    }

    /// A successful deploy has nothing to report, so it draws the same upright
    /// rocket as a quiet bar — before and after the popover is opened.
    func test_iconReadyShowsIdle() async {
        let (store, _) = singleDeploymentStore(
            Fixtures.deployment(uid: "r1", name: "alpha", state: "READY"))
        await store.poll()
        XCTAssertEqual(store.iconState, .idle)
        store.acknowledge()
        XCTAssertEqual(store.iconState, .idle)
    }

    func test_iconBuildingNeverAcknowledgedAway() async {
        let (store, _) = singleDeploymentStore(
            Fixtures.deployment(uid: "b1", name: "alpha", state: "BUILDING"))
        await store.poll()
        XCTAssertEqual(store.iconState, .building)
        store.acknowledge()
        XCTAssertEqual(store.iconState, .building)   // running stays orange
    }

    /// Selecting an account in the dropdown must show ONLY that account's rows —
    /// including a GitHub account, whose "deployments" are its Actions runs.
    func test_selectScopeShowsOnlyThatAccount() async {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        let v = accountStore.addKeychainAccount(provider: .vercel, label: "V", token: "tv")
        let g = accountStore.addKeychainAccount(provider: .github, label: "G", token: "tg")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { account, _ in
                account.id == v.id
                    ? StubClient(deps: [Fixtures.deployment(uid: "vd", name: "web")],
                                 projs: [Fixtures.project(id: "pv", name: "web")], error: nil)
                    : StubClient(deps: [Fixtures.deployment(uid: "gd", name: "acme/web")],
                                 projs: [Fixtures.project(id: "pg", name: "acme/web")], error: nil)
            },
            reloadToken: { nil }, authRetryBackoff: .zero)
        await store.poll()

        await store.select(accountId: g.id, teamId: nil)
        XCTAssertEqual(store.sourcedDeployments.map(\.deployment.uid), ["gd"])
        XCTAssertEqual(store.sourcedProjects.map(\.project.id), ["pg"])

        await store.select(accountId: v.id, teamId: nil)
        XCTAssertEqual(store.sourcedDeployments.map(\.deployment.uid), ["vd"])
        XCTAssertEqual(store.sourcedProjects.map(\.project.id), ["pv"])

        // Settings' follow list stays unfiltered.
        XCTAssertEqual(Set(store.allSourcedProjects.map(\.project.id)), ["pv", "pg"])

        // A project row can borrow its newest fetched deployment (fills the CI
        // state badge for GitHub repos, whose repo API has no latest-run info).
        let vp = store.sourcedProjects.first { $0.project.id == "pv" }!
        XCTAssertEqual(store.latestDeployment(for: vp)?.uid, "vd")
    }
}
