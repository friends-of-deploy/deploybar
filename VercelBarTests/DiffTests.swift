import XCTest
@testable import VercelBar

final class DiffTests: XCTestCase {
    private func dep(_ uid: String, _ state: String) -> DeploymentSnapshot {
        DeploymentSnapshot(uid: uid, name: "proj", state: DeploymentState(apiValue: state))
    }

    func test_firstPollIsSilent() {
        let new = [dep("1", "BUILDING"), dep("2", "ERROR")]
        XCTAssertTrue(DeploymentDiffer.transitions(previous: nil, current: new).isEmpty)
    }

    func test_buildToReadyEmitsSuccess() {
        let t = DeploymentDiffer.transitions(previous: [dep("1", "BUILDING")], current: [dep("1", "READY")])
        XCTAssertEqual(t, [StateTransition(uid: "1", project: "proj", event: .success)])
    }

    func test_buildToErrorEmitsFailure() {
        let t = DeploymentDiffer.transitions(previous: [dep("1", "BUILDING")], current: [dep("1", "ERROR")])
        XCTAssertEqual(t.map(\.event), [.failure])
    }

    func test_newBuildingEmitsStarted() {
        let t = DeploymentDiffer.transitions(previous: [], current: [dep("9", "BUILDING")])
        XCTAssertEqual(t.map(\.event), [.started])
    }

    func test_noChangeEmitsNothing() {
        let same = [dep("1", "READY")]
        XCTAssertTrue(DeploymentDiffer.transitions(previous: same, current: same).isEmpty)
    }

    func test_canceledEmitsCanceled() {
        let t = DeploymentDiffer.transitions(previous: [dep("1", "BUILDING")], current: [dep("1", "CANCELED")])
        XCTAssertEqual(t.map(\.event), [.canceled])
    }

    func test_unknownStateEmitsNothing() {
        let t = DeploymentDiffer.transitions(previous: [dep("1", "READY")], current: [dep("1", "WHATEVER")])
        XCTAssertTrue(t.isEmpty)
    }

    func test_disappearedDeploymentEmitsNothing() {
        // a deployment present before but absent now should not emit
        let t = DeploymentDiffer.transitions(previous: [dep("1", "BUILDING")], current: [])
        XCTAssertTrue(t.isEmpty)
    }

    func test_onlyChangedUidEmits() {
        let prev = [dep("1", "BUILDING"), dep("2", "READY")]
        let curr = [dep("1", "READY"),    dep("2", "READY")]
        let t = DeploymentDiffer.transitions(previous: prev, current: curr)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].uid, "1")
        XCTAssertEqual(t[0].event, .success)
    }

    func test_newUnknownDeploymentEmitsNothing() {
        let t = DeploymentDiffer.transitions(previous: [dep("1", "READY")], current: [dep("1", "READY"), dep("2", "WHATEVER")])
        XCTAssertTrue(t.isEmpty)
    }
}
