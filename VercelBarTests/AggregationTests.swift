import XCTest
@testable import VercelBar

@MainActor
final class AggregationTests: XCTestCase {
    func test_snapshotCarriesProjectKey() {
        let key = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "p")
        let snap = DeploymentSnapshot(uid: "u1", name: "web", state: .building, key: key)
        XCTAssertEqual(snap.key, key)
    }
}
