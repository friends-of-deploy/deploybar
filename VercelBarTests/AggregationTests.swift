import XCTest
@testable import VercelBar

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
                                 reloadCLIToken: { nil })
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
}
