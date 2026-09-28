import XCTest
@testable import DeployBar

final class WidgetSnapshotTests: XCTestCase {

    private func deployment(_ id: String, state: String = "READY") -> WidgetDeployment {
        WidgetDeployment(id: id, stateRaw: state, target: "production", branch: "main",
                         shortSha: "a1b2c3d", message: "fix: things", author: "octo",
                         createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                         buildingAt: nil, readyAt: nil,
                         url: URL(string: "https://vercel.com/acme/web/abc"))
    }

    private func snapshot(at date: Date, state: String = "READY") -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: date, projects: [
            WidgetProject(key: "vercel|\(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!.uuidString)|prj_1",
                          name: "web", provider: .vercel,
                          dashboardURL: URL(string: "https://vercel.com/acme/web"),
                          deployments: [deployment("d1", state: state)])
        ])
    }

    func test_roundTrip() throws {
        let original = snapshot(at: Date(timeIntervalSince1970: 1_700_000_500))
        let decoded = WidgetSnapshot.decode(try original.encoded())
        XCTAssertEqual(decoded, original)
    }

    func test_unknownVersionReadsAsAbsent() throws {
        var future = snapshot(at: .now)
        future.version = WidgetSnapshot.currentVersion + 1
        XCTAssertNil(WidgetSnapshot.decode(try future.encoded()),
                     "a widget must not render a format it doesn't understand")
    }

    func test_garbageReadsAsAbsent() {
        XCTAssertNil(WidgetSnapshot.decode(Data("not json".utf8)))
    }

    func test_sameContentIgnoresGeneratedAt() {
        let a = snapshot(at: Date(timeIntervalSince1970: 1))
        let b = snapshot(at: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(a.hasSameContent(as: b))
        XCTAssertFalse(a.hasSameContent(as: snapshot(at: Date(timeIntervalSince1970: 1), state: "ERROR")))
    }

    func test_deploymentStateComesFromRaw() {
        XCTAssertEqual(deployment("d", state: "BUILDING").state, .building)
    }

    func test_fileWriteThenRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("widget-snapshot.json")
        let original = snapshot(at: Date(timeIntervalSince1970: 1_700_000_900))
        try WidgetSnapshotFile.write(original, to: url)
        XCTAssertEqual(WidgetSnapshotFile.read(from: url), original)
    }

    func test_readMissingFileIsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(WidgetSnapshotFile.read(from: url))
        XCTAssertNil(WidgetSnapshotFile.read(from: nil))
    }
}
