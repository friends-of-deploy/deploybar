import XCTest
@testable import DeployBar

/// Exercises `GitHubClient` end-to-end with an injected `fetch`, so no network is
/// touched. Repos map to `Project`s, workflow runs map to `Deployment`s, and a
/// 401/403 surfaces as `ProviderClientError.unauthorized`.
final class GitHubClientTests: XCTestCase {

    // MARK: - Fixtures (inline, mirrors AggregationTests' self-contained style)

    private static let reposJSON = """
    [
      {"id":1,"name":"web","full_name":"acme/web","owner":{"login":"acme","avatar_url":"https://x/a.png"},
       "html_url":"https://github.com/acme/web","default_branch":"main","homepage":"https://acme.dev"},
      {"id":2,"name":"api","full_name":"acme/api","owner":{"login":"acme","avatar_url":null},
       "html_url":"https://github.com/acme/api","default_branch":"trunk","homepage":""}
    ]
    """

    private static let runsJSON = """
    {"workflow_runs":[
      {"id":100,"name":"CI","display_title":"Fix the build","head_branch":"main","head_sha":"abc123",
       "status":"completed","conclusion":"success","html_url":"https://github.com/acme/web/actions/runs/100",
       "created_at":"2024-01-02T00:00:00Z","updated_at":"2024-01-02T00:01:00Z","run_started_at":"2024-01-02T00:00:10Z",
       "actor":{"login":"octocat","avatar_url":null},"head_commit":{"message":"ignored when display_title present"}},
      {"id":99,"name":"CI","display_title":"Earlier run","head_branch":"main","head_sha":"def456",
       "status":"in_progress","conclusion":null,"html_url":"https://github.com/acme/web/actions/runs/99",
       "created_at":"2024-01-01T00:00:00Z","updated_at":null,"run_started_at":"2024-01-01T00:00:05Z",
       "actor":{"login":"octocat","avatar_url":null},"head_commit":{"message":"m"}}
    ]}
    """

    private func makeClient(runFanout: Int = 20,
                            handler: @escaping @Sendable (URLRequest) -> (Int, String)) -> GitHubClient {
        GitHubClient(token: "tok", runFanoutLimit: runFanout) { req in
            let (code, body) = handler(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
    }

    // MARK: - projects()

    func test_projects_mapReposToProjects() async throws {
        let client = makeClient { req in
            XCTAssertTrue(req.url!.path.contains("/user/repos"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            return (200, Self.reposJSON)
        }
        let projects = try await client.projects()
        XCTAssertEqual(projects.map(\.id), ["acme/web", "acme/api"])
        XCTAssertEqual(projects[0].name, "acme/web")
        XCTAssertEqual(projects[0].repoType, "github")
        XCTAssertEqual(projects[0].repoOrg, "acme")
        XCTAssertEqual(projects[0].repoName, "web")
        XCTAssertEqual(projects[0].productionBranch, "main")
        XCTAssertEqual(projects[0].productionURL, "https://acme.dev")
        // Empty homepage collapses to nil.
        XCTAssertNil(projects[1].productionURL)
        XCTAssertEqual(projects[1].productionBranch, "trunk")
    }

    // MARK: - deployments()

    func test_deployments_mapRunsSortedNewestFirst() async throws {
        // One repo keeps the fan-out deterministic.
        let oneRepo = """
        [{"id":1,"name":"web","full_name":"acme/web","owner":{"login":"acme","avatar_url":null},
          "html_url":"https://github.com/acme/web","default_branch":"main","homepage":null}]
        """
        let client = makeClient { req in
            if req.url!.path.contains("/actions/runs") { return (200, Self.runsJSON) }
            return (200, oneRepo)
        }

        let deployments = try await client.deployments(limit: 10)
        XCTAssertEqual(deployments.count, 2)

        // Newest (run 100) first.
        let first = deployments[0]
        XCTAssertEqual(first.uid, "100")
        XCTAssertEqual(first.name, "acme/web")
        XCTAssertEqual(first.state, .ready)
        XCTAssertEqual(first.commitMessage, "Fix the build")   // display_title wins
        XCTAssertEqual(first.commitRef, "main")
        XCTAssertEqual(first.commitSha, "abc123")
        XCTAssertEqual(first.commitOrg, "acme")
        XCTAssertEqual(first.commitRepo, "web")
        XCTAssertEqual(first.creatorUsername, "octocat")
        XCTAssertEqual(first.webURL, URL(string: "https://github.com/acme/web/actions/runs/100"))
        XCTAssertEqual(first.createdAt, 1_704_153_600_000)      // 2024-01-02T00:00:00Z
        XCTAssertEqual(first.ready, 1_704_153_660_000)          // updated_at, completed

        // Second, still building → no ready timestamp.
        let second = deployments[1]
        XCTAssertEqual(second.uid, "99")
        XCTAssertEqual(second.state, .building)
        XCTAssertNil(second.ready)
    }

    func test_deployments_emptyWhenNoRepos() async throws {
        let client = makeClient { _ in (200, "[]") }
        let deployments = try await client.deployments(limit: 10)
        XCTAssertTrue(deployments.isEmpty)
    }

    // MARK: - Auth

    func test_unauthorizedMapsToProviderError() async {
        let client = makeClient { _ in (401, "{}") }
        do {
            _ = try await client.projects()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ProviderClientError, .unauthorized)
        }
    }

    func test_forbiddenAlsoUnauthorized() async {
        let client = makeClient { _ in (403, "{}") }
        do {
            _ = try await client.projects()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ProviderClientError, .unauthorized)
        }
    }
}
