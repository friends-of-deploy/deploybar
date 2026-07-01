import XCTest
@testable import DeployBar

final class DeploymentTimingTests: XCTestCase {
    func test_durationUnderMinuteIsSeconds() {
        XCTAssertEqual(DeploymentTiming.duration(seconds: 56), "56s")
        XCTAssertEqual(DeploymentTiming.duration(seconds: 0), "0s")
    }

    func test_durationWholeMinutes() {
        XCTAssertEqual(DeploymentTiming.duration(seconds: 120), "2m")
    }

    func test_durationMinutesAndSeconds() {
        XCTAssertEqual(DeploymentTiming.duration(seconds: 95), "1m 35s")
    }

    func test_buildPhase_inProgressShowsBuilding() {
        let d = makeDeployment(state: "BUILDING", buildingAt: 1000, ready: nil)
        XCTAssertEqual(DeploymentTiming.buildPhase(d), "building…")
    }

    func test_buildPhase_finishedShowsBuiltDuration() {
        // building at t=1000ms, ready at t=57000ms → 56s
        let d = makeDeployment(state: "READY", buildingAt: 1000, ready: 57000)
        XCTAssertEqual(DeploymentTiming.buildPhase(d), "built in 56s")
    }

    func test_buildPhase_missingTimestampsIsEmpty() {
        let d = makeDeployment(state: "READY", buildingAt: nil, ready: nil)
        XCTAssertEqual(DeploymentTiming.buildPhase(d), "")
    }

    func test_relativeJustNow() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        XCTAssertEqual(DeploymentTiming.relative(epochMs: nowMs), "just now")
    }

    // MARK: - Helper: build a Deployment by decoding minimal JSON

    private func makeDeployment(state: String, buildingAt: Double?, ready: Double?) -> Deployment {
        var fields = #""uid":"d","name":"p","state":"\#(state)","url":"x.vercel.app","createdAt":1000"#
        if let buildingAt { fields += ",\"buildingAt\":\(buildingAt)" }
        if let ready { fields += ",\"ready\":\(ready)" }
        let json = "{\"deployments\":[{\(fields)}]}"
        return try! JSONDecoder().decode(DeploymentsResponse.self, from: Data(json.utf8)).deployments[0]
    }
}
