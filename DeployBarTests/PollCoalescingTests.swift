import XCTest
@testable import DeployBar

/// `poll()` used to open with `guard !isPollInFlight else { return }`, which
/// silently *dropped* a racing request. `switchScope`/`selectAll` mutate the
/// active scope and then `await poll()` to fetch it, so a poll that collided
/// with the periodic timer left the popover showing the previous scope's rows
/// under the new scope's label until the next tick. Requests are now coalesced:
/// a racing caller waits for the in-flight run and then gets a real fetch.
@MainActor
final class PollCoalescingTests: XCTestCase {

    /// Counts fetches and can be held open to keep a poll in flight.
    private final class Recorder: @unchecked Sendable {
        private(set) var fetches = 0
        var gate: (() async -> Void)?
        func record() async {
            fetches += 1
            await gate?()
        }
    }

    private struct StubClient: DeploymentProviderClient {
        let recorder: Recorder
        func deployments(limit: Int) async throws -> [Deployment] {
            await recorder.record()
            return []
        }
        func projects() async throws -> [Project] { [] }
    }

    private func makeStore(_ recorder: Recorder) -> DeploymentStore {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false },
                                        reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        _ = accountStore.addKeychainAccount(provider: .vercel, label: "A", token: "tok")
        return DeploymentStore(
            accountStore: accountStore,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { _, _ in StubClient(recorder: recorder) },
            reloadToken: { nil },
            authRetryBackoff: .zero
        )
    }

    /// The core regression: a second `poll()` arriving while the first is in
    /// flight must still produce its own fetch, not be discarded.
    func test_pollDuringInFlightPollStillFetches() async {
        let recorder = Recorder()
        let store = makeStore(recorder)

        // Hold the first poll open until we have launched the second.
        let released = expectation(description: "first poll released")
        var release: (() -> Void)?
        recorder.gate = {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                release = { c.resume() }
                released.fulfill()
            }
            recorder.gate = nil     // only gate the first fetch
        }

        let first = Task { await store.poll() }
        await fulfillment(of: [released], timeout: 2)

        // Second caller races the in-flight poll.
        let second = Task { await store.poll() }
        release?()

        await first.value
        await second.value

        XCTAssertEqual(recorder.fetches, 2,
                       "the racing poll must fetch too — it used to be dropped by the re-entrancy guard")
    }

    /// The guard's original purpose survives: a poll is never re-entered
    /// concurrently, so the two runs are sequential rather than interleaved.
    func test_pollsDoNotOverlap() async {
        let recorder = Recorder()
        let store = makeStore(recorder)

        var concurrent = 0
        var maxConcurrent = 0
        recorder.gate = {
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            await Task.yield()
            concurrent -= 1
        }

        async let a: Void = store.poll()
        async let b: Void = store.poll()
        async let c: Void = store.poll()
        _ = await (a, b, c)

        XCTAssertEqual(maxConcurrent, 1, "polls must not run concurrently")
        XCTAssertGreaterThanOrEqual(recorder.fetches, 2, "racing callers must not be silently dropped")
    }

    /// A plain sequential poll still fetches exactly once — no double-run from
    /// the coalescing bookkeeping.
    func test_sequentialPollsFetchOncePerCall() async {
        let recorder = Recorder()
        let store = makeStore(recorder)

        await store.poll()
        await store.poll()

        XCTAssertEqual(recorder.fetches, 2)
    }

    // MARK: - Budget

    func test_effectiveIntervalGrowsWithManyOrganizations() {
        let (store, _, settings) = Self.makeStore(accounts: [Self.gitHubAccount])
        settings.pollIntervalSeconds = 30
        store.setOrganizations((0..<40).map { Team(id: "org\($0)", slug: "org\($0)", name: "org\($0)") },
                               for: Self.gitHubAccount.id)

        // 41 scopes cannot all be polled every 30s inside GitHub's hourly limit.
        XCTAssertGreaterThan(store.effectiveRefreshInterval(for: Self.gitHubAccount), 30)
    }

    func test_effectiveIntervalIsThePollIntervalWithFewOrganizations() {
        let (store, _, settings) = Self.makeStore(accounts: [Self.gitHubAccount])
        settings.pollIntervalSeconds = 30
        store.setOrganizations([Team(id: "Vorciu", slug: "Vorciu", name: "Vorciu")],
                               for: Self.gitHubAccount.id)

        XCTAssertEqual(store.effectiveRefreshInterval(for: Self.gitHubAccount), 30)
    }

    // MARK: - Budget fixtures

    /// A fixed-identity GitHub account, mirroring `ScopeColorTests`' fixture —
    /// these tests never poll it (no organizations client is wired up), they
    /// only exercise the pure budget math through `effectiveRefreshInterval`.
    private static let gitHubAccount = Account(
        id: UUID(uuidString: "8B1C2D3E-0000-0000-0000-0000000000B1")!,
        provider: .github, label: "GitHub", source: .keychain(account: "gh-budget-fixture"))

    /// Builds a `DeploymentStore` around a fresh `AccountStore` seeded with the
    /// given accounts. `DeploymentStore.settings` is private, so the
    /// `SettingsStore` used to build the store is returned alongside it for
    /// tests that need `pollIntervalSeconds` directly.
    private static func makeStore(accounts: [Account]) -> (DeploymentStore, [Account], SettingsStore) {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        for account in accounts {
            accountStore.adoptDemoAccount(account)
        }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, _ in nil },
            reloadToken: { nil }, authRetryBackoff: .zero)
        return (store, accounts, settings)
    }
}
