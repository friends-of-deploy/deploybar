import XCTest
@testable import DeployBar

final class WidgetSnapshotBuilderTests: XCTestCase {

    private let vercel = Account(id: UUID(), provider: .vercel, label: "V", source: .keychain(account: "v"))
    private let github = Account(id: UUID(), provider: .github, label: "G", source: .keychain(account: "g"))
    private let asOf = Date(timeIntervalSince1970: 1_700_000_000)

    private func sd(_ account: Account, project: String, uid: String, ms: Double,
                    state: String = "READY") -> SourcedDeployment {
        SourcedDeployment(deployment: Deployment(
            uid: uid, name: project, stateRaw: state, target: "production", url: "\(uid).vercel.app",
            inspectorUrl: "https://vercel.com/acme/\(project)/\(uid)", createdAt: ms, buildingAt: ms + 1000,
            ready: nil, creatorUsername: "creator", commitSha: "a1b2c3d4e5f6", commitRef: "main",
            commitMessage: "fix: stuff", commitAuthorLogin: "author"), account: account)
    }

    private func sp(_ account: Account, id: String, name: String) -> SourcedProject {
        SourcedProject(project: Project(id: id, name: name), account: account)
    }

    private func build(_ projects: [SourcedProject], _ deployments: [SourcedDeployment]) -> WidgetSnapshot {
        WidgetSnapshotBuilder.build(projects: projects, deployments: deployments,
                                    dashboardURL: { URL(string: "https://dash/\($0.project.name)") },
                                    generatedAt: asOf)
    }

    func test_mapsProjectAndDeploymentFields() throws {
        let snap = build([sp(vercel, id: "prj_1", name: "web")],
                         [sd(vercel, project: "web", uid: "d1", ms: 1_700_000_000_000, state: "BUILDING")])
        XCTAssertEqual(snap.generatedAt, asOf)
        let p = try XCTUnwrap(snap.projects.first)
        XCTAssertEqual(p.key, ProjectKey(provider: .vercel, accountId: vercel.id, projectId: "prj_1").storageString)
        XCTAssertEqual(p.provider, .vercel)
        XCTAssertEqual(p.dashboardURL?.absoluteString, "https://dash/web")
        let d = try XCTUnwrap(p.deployments.first)
        XCTAssertEqual(d.id, "d1")
        XCTAssertEqual(d.state, .building)
        XCTAssertEqual(d.shortSha, "a1b2c3d")
        XCTAssertEqual(d.branch, "main")
        XCTAssertEqual(d.author, "author")
        XCTAssertEqual(d.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(d.buildingAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(d.url?.absoluteString, "https://vercel.com/acme/web/d1")
    }

    func test_keepsSixNewestDeploymentsNewestFirst() {
        let deps = (0..<9).map { sd(vercel, project: "web", uid: "d\($0)", ms: Double($0) * 1000) }
        let ids = build([sp(vercel, id: "p", name: "web")], deps).projects.first?.deployments.map(\.id)
        XCTAssertEqual(ids, ["d8", "d7", "d6", "d5", "d4", "d3"])
    }

    func test_matchesDeploymentsByAccountAndName() {
        let snap = build([sp(vercel, id: "p1", name: "web"), sp(github, id: "p2", name: "web")],
                         [sd(vercel, project: "web", uid: "v", ms: 1), sd(github, project: "web", uid: "g", ms: 2)])
        XCTAssertEqual(snap.projects.map { $0.deployments.map(\.id) }, [["v"], ["g"]])
    }

    func test_authorFallsBackToCreator() {
        let d = Deployment(uid: "x", name: "web", stateRaw: "READY", url: "x", createdAt: 0, creatorUsername: "bot")
        let snap = build([sp(vercel, id: "p", name: "web")], [SourcedDeployment(deployment: d, account: vercel)])
        XCTAssertEqual(snap.projects.first?.deployments.first?.author, "bot")
    }

    func test_duplicateProjectFromTwoScopesAppearsOnce() {
        let snap = build([sp(vercel, id: "p", name: "web"), sp(vercel, id: "p", name: "web")], [])
        XCTAssertEqual(snap.projects.count, 1)
    }
}
