import XCTest
@testable import DeployBar

final class DeploymentFaviconTests: XCTestCase {
    private func deployment(name: String, url: String) throws -> Deployment {
        let json = """
        {"uid":"dpl_1","name":"\(name)","state":"READY","url":"\(url)","createdAt":1}
        """
        return try JSONDecoder().decode(Deployment.self, from: Data(json.utf8))
    }

    private func project(name: String, url: String?, aliases: [String]) throws -> Project {
        let aliasJSON = aliases.map { "\"\($0)\"" }.joined(separator: ",")
        let urlJSON = url.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"projects":[{"id":"prj_1","name":"\(name)",
          "targets":{"production":{"url":\(urlJSON),"alias":[\(aliasJSON)]}}}]}
        """
        return try JSONDecoder().decode(ProjectsResponse.self, from: Data(json.utf8)).projects[0]
    }

    func test_usesMatchingProjectsBrandableHost() throws {
        // The deployment's own url is the hashed per-deployment host with no favicon;
        // we should resolve the project's clean custom domain instead.
        let dep = try deployment(name: "web-app", url: "web-app-a1b2c3d4-acme.vercel.app")
        let proj = try project(name: "web-app", url: "web-app-a1b2c3d4-acme.vercel.app",
                               aliases: ["web-app.example.com", "web-app-acme.vercel.app"])
        XCTAssertEqual(DeploymentFavicon.host(for: dep, in: [proj]), "web-app.example.com")
    }

    func test_fallsBackToDeploymentURLWhenNoMatchingProject() throws {
        let dep = try deployment(name: "orphan", url: "orphan-xyz.vercel.app")
        let proj = try project(name: "other", url: "other.vercel.app", aliases: [])
        XCTAssertEqual(DeploymentFavicon.host(for: dep, in: [proj]), "orphan-xyz.vercel.app")
    }

    func test_fallsBackToDeploymentURLWhenProjectHasNoHost() throws {
        let dep = try deployment(name: "noprod", url: "noprod-xyz.vercel.app")
        let proj = try project(name: "noprod", url: nil, aliases: [])
        XCTAssertEqual(DeploymentFavicon.host(for: dep, in: [proj]), "noprod-xyz.vercel.app")
    }

    func test_nilWhenNoProjectAndEmptyURL() throws {
        let dep = try deployment(name: "blank", url: "")
        XCTAssertNil(DeploymentFavicon.host(for: dep, in: []))
    }
}
