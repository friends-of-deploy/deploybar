import XCTest
@testable import DeployBar

final class RowPrimaryActionTests: XCTestCase {
    func test_readyDeploymentOpensLiveSite() {
        let d = makeDeployment(state: "READY", url: "dashboard-abc.vercel.app", inspectorUrl: "https://vercel.com/x/insp")
        XCTAssertEqual(DeploymentRow.primaryDestination(for: d)?.absoluteString,
                       "https://dashboard-abc.vercel.app")
    }

    func test_failedDeploymentOpensLogs() {
        let d = makeDeployment(state: "ERROR", url: "dashboard-abc.vercel.app", inspectorUrl: "https://vercel.com/x/insp")
        XCTAssertEqual(DeploymentRow.primaryDestination(for: d)?.absoluteString,
                       "https://vercel.com/x/insp")
    }

    func test_buildingDeploymentOpensLiveSite() {
        let d = makeDeployment(state: "BUILDING", url: "x.vercel.app", inspectorUrl: "https://vercel.com/x/insp")
        XCTAssertEqual(DeploymentRow.primaryDestination(for: d)?.absoluteString, "https://x.vercel.app")
    }

    func test_failedWithoutLogsFallsBackToSite() {
        let d = makeDeployment(state: "ERROR", url: "x.vercel.app", inspectorUrl: nil)
        XCTAssertEqual(DeploymentRow.primaryDestination(for: d)?.absoluteString, "https://x.vercel.app")
    }

    private func makeDeployment(state: String, url: String, inspectorUrl: String?) -> Deployment {
        var fields = #""uid":"d","name":"p","state":"\#(state)","url":"\#(url)","createdAt":1000"#
        if let inspectorUrl { fields += ",\"inspectorUrl\":\"\(inspectorUrl)\"" }
        let json = "{\"deployments\":[{\(fields)}]}"
        return try! JSONDecoder().decode(DeploymentsResponse.self, from: Data(json.utf8)).deployments[0]
    }
}
