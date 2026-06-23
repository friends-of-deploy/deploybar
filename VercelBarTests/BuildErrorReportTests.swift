import XCTest
@testable import VercelBar

final class BuildErrorReportTests: XCTestCase {
    func test_logTail_keepsStdoutAndStderrInOrder() {
        let events = [
            BuildEvent(type: "stdout", text: "Installing dependencies"),
            BuildEvent(type: "stdout", text: "Running build"),
            BuildEvent(type: "stderr", text: "error TS2304: Cannot find name 'foo'"),
        ]
        XCTAssertEqual(
            BuildErrorReport.logTail(from: events),
            "Installing dependencies\nRunning build\nerror TS2304: Cannot find name 'foo'"
        )
    }

    func test_logTail_dropsNonLogEvents() {
        let events = [
            BuildEvent(type: "delimiter", text: nil),
            BuildEvent(type: "stdout", text: "real output"),
        ]
        XCTAssertEqual(BuildErrorReport.logTail(from: events), "real output")
    }

    /// The events endpoint returns a flat array with `text` at the top level —
    /// not nested under `payload`. Regression guard for that decoding.
    func test_decode_readsTopLevelText() throws {
        let json = """
        [
          {"type":"stdout","text":"Running build in iad1","created":1782208327345},
          {"type":"stderr","text":"Error: NEXT_PUBLIC_CONVEX_URL is not set","level":"error","created":1782208327999}
        ]
        """
        let events = try JSONDecoder().decode([BuildEvent].self, from: Data(json.utf8))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].text, "Running build in iad1")
        XCTAssertEqual(events[1].text, "Error: NEXT_PUBLIC_CONVEX_URL is not set")
        XCTAssertEqual(events[1].level, "error")
        XCTAssertEqual(
            BuildErrorReport.logTail(from: events),
            "Running build in iad1\nError: NEXT_PUBLIC_CONVEX_URL is not set"
        )
    }

    func test_logTail_splitsMultilineText() {
        let events = [BuildEvent(type: "stderr", text: "line one\nline two")]
        XCTAssertEqual(BuildErrorReport.logTail(from: events), "line one\nline two")
    }

    func test_logTail_keepsOnlyTrailingLines() {
        let many = (1...(BuildErrorReport.tailLineCount + 10)).map {
            BuildEvent(type: "stdout", text: "line \($0)")
        }
        let lines = BuildErrorReport.logTail(from: many).split(separator: "\n")
        XCTAssertEqual(lines.count, BuildErrorReport.tailLineCount)
        XCTAssertEqual(lines.first, "line 11")
        XCTAssertEqual(lines.last, "line \(BuildErrorReport.tailLineCount + 10)")
    }

    func test_logTail_emptyEventsHasPlaceholder() {
        XCTAssertEqual(BuildErrorReport.logTail(from: []), "(no build output captured)")
    }

    func test_make_includesContextHeaderAndLog() {
        let d = makeDeployment()
        let report = BuildErrorReport.make(
            for: d,
            events: [BuildEvent(type: "stderr", text: "boom")]
        )
        XCTAssertTrue(report.contains("Vercel deployment failed"))
        XCTAssertTrue(report.contains("Project: my-app"))
        XCTAssertTrue(report.contains("Branch: main"))
        XCTAssertTrue(report.contains("Logs: https://vercel.com/inspect"))
        XCTAssertTrue(report.contains("boom"))
    }

    // MARK: - Helper

    private func makeDeployment() -> Deployment {
        let json = """
        {"deployments":[{
          "uid":"dpl_1","name":"my-app","state":"ERROR","url":"my-app.vercel.app",
          "inspectorUrl":"https://vercel.com/inspect","createdAt":1000,
          "meta":{"githubCommitRef":"main","githubCommitMessage":"fix things"}
        }]}
        """
        return try! JSONDecoder().decode(DeploymentsResponse.self, from: Data(json.utf8)).deployments[0]
    }
}
