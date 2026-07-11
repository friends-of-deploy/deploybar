import XCTest
@testable import DeployBar

/// Pure mapping from GitHub Actions run status/conclusion + ISO timestamps onto
/// the app's shared `DeploymentState` / epoch-millisecond model.
final class GitHubStateMappingTests: XCTestCase {

    private func state(_ status: String?, _ conclusion: String?) -> DeploymentState {
        DeploymentState(apiValue: GitHubClient.githubState(status: status, conclusion: conclusion))
    }

    func test_inProgressIsBuilding() {
        XCTAssertEqual(state("in_progress", nil), .building)
    }

    func test_queuedVariantsAreQueued() {
        for s in ["queued", "requested", "waiting", "pending"] {
            XCTAssertEqual(state(s, nil), .queued, "status \(s)")
        }
    }

    func test_completedSuccessIsReady() {
        XCTAssertEqual(state("completed", "success"), .ready)
    }

    func test_completedFailuresAreError() {
        for c in ["failure", "timed_out", "startup_failure"] {
            XCTAssertEqual(state("completed", c), .error, "conclusion \(c)")
        }
    }

    func test_completedCancelledIsCanceled() {
        XCTAssertEqual(state("completed", "cancelled"), .canceled)
    }

    func test_completedNeutralOutcomesAreUnknown() {
        for c in ["skipped", "neutral", "action_required", "stale", nil] {
            XCTAssertEqual(state("completed", c), .unknown, "conclusion \(c ?? "nil")")
        }
    }

    func test_unrecognizedStatusIsUnknown() {
        XCTAssertEqual(state("something_new", nil), .unknown)
        XCTAssertEqual(state(nil, nil), .unknown)
    }

    // MARK: - Timestamps

    func test_epochMsParsesISO8601ToMilliseconds() {
        // 2024-01-01T00:00:00Z == 1704067200 s == 1704067200000 ms
        XCTAssertEqual(GitHubClient.epochMs("2024-01-01T00:00:00Z"), 1_704_067_200_000)
    }

    func test_epochMsNilOnBadInput() {
        XCTAssertNil(GitHubClient.epochMs(nil))
        XCTAssertNil(GitHubClient.epochMs("not-a-date"))
    }
}
