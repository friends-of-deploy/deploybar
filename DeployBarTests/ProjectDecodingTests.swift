import XCTest
@testable import DeployBar

final class ProjectDecodingTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func test_decodesProjectsResponse() throws {
        let resp = try JSONDecoder().decode(ProjectsResponse.self, from: fixtureData("projects"))
        XCTAssertFalse(resp.projects.isEmpty)
        XCTAssertFalse(resp.projects[0].name.isEmpty)
    }

    func test_exposesGithubLinkAndLatestState() throws {
        let resp = try JSONDecoder().decode(ProjectsResponse.self, from: fixtureData("projects"))
        XCTAssertFalse(resp.projects.isEmpty, "fixture must contain projects")
        let linked = resp.projects.filter { $0.repoOrg != nil && $0.repoName != nil }
        XCTAssertFalse(linked.isEmpty, "fixture must contain at least one github-linked project")
        // latestState only resolves to a real state when latestStateRaw is present
        XCTAssertTrue(resp.projects.allSatisfy { $0.latestState != .unknown || $0.latestStateRaw == nil })
    }

    // Covers the try? fallback paths: a project with no git link, no latestDeployments, no targets.
    func test_decodesProjectWithoutLinkOrDeployments() throws {
        let json = """
        {"projects":[{"id":"prj_x","name":"bare"}]}
        """
        let resp = try JSONDecoder().decode(ProjectsResponse.self, from: Data(json.utf8))
        let p = resp.projects[0]
        XCTAssertEqual(p.name, "bare")
        XCTAssertNil(p.repoOrg)
        XCTAssertNil(p.repoName)
        XCTAssertNil(p.productionURL)
        XCTAssertNil(p.latestStateRaw)
        XCTAssertEqual(p.latestState, .unknown)
        // New fields default sensibly when absent.
        XCTAssertNil(p.framework)
        XCTAssertNil(p.productionBranch)
        XCTAssertEqual(p.envCount, 0)
        XCTAssertEqual(p.cronCount, 0)
        XCTAssertFalse(p.hasAnalytics)
    }

    func test_exposesFrameworkBranchEnvCount() throws {
        let resp = try JSONDecoder().decode(ProjectsResponse.self, from: fixtureData("projects"))
        // The real fixture has a project with env vars and a production branch.
        XCTAssertTrue(resp.projects.contains { $0.envCount > 0 }, "fixture should have a project with env vars")
        XCTAssertTrue(resp.projects.contains { $0.productionBranch == "main" })
        XCTAssertTrue(resp.projects.contains { $0.framework == "nextjs" })
        XCTAssertTrue(resp.projects.contains { $0.hasAnalytics })
    }

    func test_countsEnvCronsFromInlineJSON() throws {
        let json = """
        {"projects":[{"id":"p","name":"x","framework":"nextjs","nodeVersion":"24.x",
          "link":{"type":"github","org":"o","repo":"r","productionBranch":"main"},
          "env":[{"key":"A"},{"key":"B"},{"key":"C"}],
          "crons":{"definitions":[{"path":"/a"},{"path":"/b"}]},
          "webAnalytics":{"id":"wa_1"}}]}
        """
        let p = try JSONDecoder().decode(ProjectsResponse.self, from: Data(json.utf8)).projects[0]
        XCTAssertEqual(p.envCount, 3)
        XCTAssertEqual(p.cronCount, 2)
        XCTAssertEqual(p.framework, "nextjs")
        XCTAssertEqual(p.nodeVersion, "24.x")
        XCTAssertEqual(p.productionBranch, "main")
        XCTAssertTrue(p.hasAnalytics)
    }

    func test_analyticsFalseWhenIdNull() throws {
        let json = #"{"projects":[{"id":"p","name":"x","webAnalytics":{"id":null}}]}"#
        let p = try JSONDecoder().decode(ProjectsResponse.self, from: Data(json.utf8)).projects[0]
        XCTAssertFalse(p.hasAnalytics)
    }

    func test_faviconHostPrefersCustomDomain() throws {
        let resp = try JSONDecoder().decode(ProjectsResponse.self, from: fixtureData("projects"))
        // web-app has a custom domain alias (web-app.example.com) — favicon host
        // must be the custom domain, not the hashed deployment URL.
        let webApp = try XCTUnwrap(resp.projects.first { $0.name == "web-app" })
        XCTAssertEqual(webApp.faviconHost, "web-app.example.com")
        XCTAssertFalse(webApp.productionAliases.isEmpty)
    }
}
