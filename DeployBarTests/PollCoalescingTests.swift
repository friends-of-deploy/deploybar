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
}
