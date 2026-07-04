import XCTest
@testable import DeployBar

final class GitHubActionsErrorReportTests: XCTestCase {

    /// Builds a `GHJob` (Decodable-only DTO) from a JSON string with inline steps.
    private func job(_ name: String, _ conclusion: String, steps: [(String, String)] = []) -> GHJob {
        let stepsJSON = steps
            .map { #"{"name":"\#($0.0)","conclusion":"\#($0.1)","number":1}"# }
            .joined(separator: ",")
        let json = #"{"id":1,"name":"\#(name)","status":"completed","conclusion":"\#(conclusion)","html_url":"h","steps":[\#(stepsJSON)]}"#
        return try! JSONDecoder().decode(GHJob.self, from: Data(json.utf8))
    }

    private let dep = Deployment(uid: "5", name: "acme/web", stateRaw: "ERROR", url: "",
                                 createdAt: 0, commitRef: "main", commitMessage: "Ship it",
                                 webURL: URL(string: "https://github.com/acme/web/actions/runs/5"))

    func test_headerAndFailedJobs() {
        let jobs = [job("test", "failure", steps: [("Run tests", "failure"), ("Setup", "success")])]
        let out = GitHubActionsErrorReport.make(deployment: dep, failedJobs: jobs, logTail: nil)
        XCTAssertTrue(out.contains("Repository: acme/web"))
        XCTAssertTrue(out.contains("Branch: main"))
        XCTAssertTrue(out.contains("Run: Ship it"))
        XCTAssertTrue(out.contains("Failed job: test"))
        XCTAssertTrue(out.contains("✗ Run tests"))
        XCTAssertFalse(out.contains("✗ Setup"))
    }

    func test_logTailTrimmedToLastLines() {
        let raw = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let out = GitHubActionsErrorReport.make(deployment: dep, failedJobs: [], logTail: raw)
        XCTAssertTrue(out.contains("line 100"))
        XCTAssertFalse(out.contains("line 1\n"))            // early lines dropped
        XCTAssertTrue(out.contains("(no failed jobs reported)"))
    }

    func test_emptyLogOmitsLogSection() {
        let out = GitHubActionsErrorReport.make(deployment: dep, failedJobs: [], logTail: "   \n  ")
        XCTAssertFalse(out.contains("Job log (tail)"))
    }

    func test_isFailureClassification() {
        for c in ["failure", "timed_out", "startup_failure"] {
            XCTAssertTrue(GitHubActionsErrorReport.isFailure(c), c)
        }
        for c in ["success", "cancelled", "skipped", nil] {
            XCTAssertFalse(GitHubActionsErrorReport.isFailure(c), c ?? "nil")
        }
    }
}
