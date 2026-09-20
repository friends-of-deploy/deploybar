import XCTest
@testable import DeployBar

final class DiffTests: XCTestCase {
    private static let key = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "proj")
    private func dep(_ uid: String, _ state: String) -> DeploymentSnapshot {
        DeploymentSnapshot(uid: uid, name: "proj", state: DeploymentState(apiValue: state), key: Self.key)
    }

    func test_firstPollIsSilent() {
        let new = [dep("1", "BUILDING"), dep("2", "ERROR")]
        XCTAssertTrue(DeploymentDiffer.transitions(previous: nil, current: new).isEmpty)
    }

    func test_buildToReadyEmitsSuccess() {
        let t = DeploymentDiffer.transitions(previous: [dep("1", "BUILDING")], current: [dep("1", "READY")])
        XCTAssertEqual(t, [StateTransition(uid: "1", project: "proj", key: Self.key, event: .success)])
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

    func test_transitionCarriesBuildDestination() {
        let destination = URL(string: "https://vercel.com/acme/app/build-1")!
        let site = URL(string: "https://app.vercel.app")!
        let current = DeploymentSnapshot(uid: "1", name: "proj", state: .error,
                                         key: Self.key, destinationURL: destination, siteURL: site)

        let transition = DeploymentDiffer.transitions(previous: [dep("1", "BUILDING")],
                                                       current: [current]).first

        XCTAssertEqual(transition?.destinationURL, destination)
        XCTAssertEqual(transition?.siteURL, site)
    }

    func test_vercelSnapshotSeparatesDeploymentPageFromSiteForEveryState() {
        for state in ["READY", "BUILDING", "ERROR", "CANCELED"] {
            let deployment = Deployment(uid: "build", name: "app", stateRaw: state,
                                        url: "app.vercel.app",
                                        inspectorUrl: "https://vercel.com/acme/app/build", createdAt: 1)
            let snapshot = DeploymentSnapshot(deployment, key: Self.key)
            XCTAssertEqual(snapshot.destinationURL?.absoluteString, deployment.inspectorUrl)
            XCTAssertEqual(snapshot.siteURL?.absoluteString, "https://app.vercel.app")
        }
    }

    func test_githubSnapshotHasRunDestinationAndNoSite() {
        let runURL = URL(string: "https://github.com/acme/app/actions/runs/1")!
        let deployment = Deployment(uid: "run", name: "app", stateRaw: "READY", url: "",
                                    createdAt: 1, webURL: runURL)
        let snapshot = DeploymentSnapshot(deployment, key: Self.key)
        XCTAssertEqual(snapshot.destinationURL, runURL)
        XCTAssertNil(snapshot.siteURL)
    }
}
