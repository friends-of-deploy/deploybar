import XCTest
@testable import VercelBar

final class DeploymentDecodingTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func test_decodesDeploymentsResponse() throws {
        let data = try fixtureData("deployments")
        let resp = try JSONDecoder().decode(DeploymentsResponse.self, from: data)
        XCTAssertFalse(resp.deployments.isEmpty)
        let first = resp.deployments[0]
        XCTAssertFalse(first.uid.isEmpty)
        XCTAssertFalse(first.name.isEmpty)
        XCTAssertNotEqual(first.state, .unknown)
    }

    func test_mapsStateStrings() {
        XCTAssertEqual(DeploymentState(apiValue: "READY"), .ready)
        XCTAssertEqual(DeploymentState(apiValue: "BUILDING"), .building)
        XCTAssertEqual(DeploymentState(apiValue: "QUEUED"), .queued)
        XCTAssertEqual(DeploymentState(apiValue: "ERROR"), .error)
        XCTAssertEqual(DeploymentState(apiValue: "CANCELED"), .canceled)
        XCTAssertEqual(DeploymentState(apiValue: "WHATEVER"), .unknown)
        XCTAssertEqual(DeploymentState(apiValue: "INITIALIZING"), .building)
    }

    func test_decodesDeploymentWithoutGitMetadataOrCreator() throws {
        let json = """
        {"deployments":[{"uid":"dpl_x","name":"manual","state":"READY","url":"manual.vercel.app","createdAt":1700000000000}]}
        """
        let resp = try JSONDecoder().decode(DeploymentsResponse.self, from: Data(json.utf8))
        let d = resp.deployments[0]
        XCTAssertEqual(d.state, .ready)
        XCTAssertNil(d.commitMessage)
        XCTAssertNil(d.commitOrg)
        XCTAssertNil(d.commitSha)
        XCTAssertNil(d.creatorUsername)
        XCTAssertNil(d.inspectorUrl)
    }

    func test_exposesGitMetadata() throws {
        let data = try fixtureData("deployments")
        let resp = try JSONDecoder().decode(DeploymentsResponse.self, from: data)
        XCTAssertTrue(resp.deployments.contains { $0.commitMessage != nil })
    }
}
