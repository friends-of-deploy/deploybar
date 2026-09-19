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
       "html_url":"https://github.com/acme/web","default_branch":"main","homepage":"https://acme.dev",
       "language":"Swift","stargazers_count":42,"open_issues_count":3,"private":true,
       "pushed_at":"2024-01-02T00:00:00Z"},
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
        // Homepage URL is normalized to a bare host (Vercel-style), so the
        // live-site link and favicon fetch work unchanged.
        XCTAssertEqual(projects[0].productionURL, "acme.dev")
        // Repo stats surface on the project row.
        XCTAssertEqual(projects[0].framework, "Swift")          // language fills the framework chip
        XCTAssertEqual(projects[0].starCount, 42)
        XCTAssertEqual(projects[0].openIssueCount, 3)
        XCTAssertEqual(projects[0].isPrivate, true)
        XCTAssertEqual(projects[0].pushedAt, 1_704_153_600_000) // 2024-01-02T00:00:00Z
        XCTAssertEqual(projects[0].iconURL, "https://x/a.png")  // owner avatar as row icon
        // Empty homepage collapses to nil.
        XCTAssertNil(projects[1].productionURL)
        XCTAssertEqual(projects[1].productionBranch, "trunk")
        // Stats absent → nils, so Vercel-style chips stay hidden.
        XCTAssertNil(projects[1].framework)
        XCTAssertNil(projects[1].starCount)
        XCTAssertNil(projects[1].iconURL)
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

    // MARK: - Failure report (copy error)

    func test_failureReport_summarizesFailedJobsAndLogTail() async throws {
        let jobsJSON = """
        {"jobs":[
          {"id":11,"name":"build","status":"completed","conclusion":"success","html_url":"h","steps":[]},
          {"id":12,"name":"test","status":"completed","conclusion":"failure","html_url":"h",
           "steps":[{"name":"Checkout","status":"completed","conclusion":"success","number":1},
                    {"name":"Run tests","status":"completed","conclusion":"failure","number":3}]}
        ]}
        """
        let logText = "setup\ninstall\nError: boom\n"
        let client = makeClient { req in
            if req.url!.path.contains("/jobs/12/logs") { return (200, logText) }
            if req.url!.path.contains("/actions/runs/100/jobs") { return (200, jobsJSON) }
            return (200, "{}")
        }
        let dep = Deployment(uid: "100", name: "acme/web", stateRaw: "ERROR", url: "",
                             createdAt: 0, commitRef: "main", commitMessage: "Fix things",
                             webURL: URL(string: "https://github.com/acme/web/actions/runs/100"))

        let report = try await client.failureReport(for: dep)
        XCTAssertTrue(report.contains("GitHub Actions run failed"))
        XCTAssertTrue(report.contains("Repository: acme/web"))
        XCTAssertTrue(report.contains("Branch: main"))
        XCTAssertTrue(report.contains("Failed job: test"))
        XCTAssertTrue(report.contains("✗ Run tests"))
        XCTAssertFalse(report.contains("✗ Checkout"))       // successful step excluded
        XCTAssertFalse(report.contains("Failed job: build")) // successful job excluded
        XCTAssertTrue(report.contains("Error: boom"))        // log tail included
    }

    func test_failureReport_toleratesMissingLog() async throws {
        let jobsJSON = """
        {"jobs":[{"id":12,"name":"deploy","status":"completed","conclusion":"failure","html_url":"h","steps":[]}]}
        """
        let client = makeClient { req in
            if req.url!.path.contains("/logs") { return (500, "boom") }   // log fetch fails
            return (200, jobsJSON)
        }
        let dep = Deployment(uid: "100", name: "acme/api", stateRaw: "ERROR", url: "", createdAt: 0,
                             webURL: URL(string: "https://github.com/acme/api/actions/runs/100"))
        let report = try await client.failureReport(for: dep)
        XCTAssertTrue(report.contains("Failed job: deploy"))
        XCTAssertFalse(report.contains("Job log (tail)"))    // gracefully omitted
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

    // MARK: - Organization scoping

    func test_accountScopeListsOwnedRepositoriesOnly() async throws {
        var paths: [String] = []
        var queries: [String] = []
        let client = GitHubClient(token: "t") { req in
            paths.append(req.url?.path ?? "")
            queries.append(req.url?.query ?? "")
            return (Data("[]".utf8), Self.ok(req))
        }

        _ = try await client.projects()

        XCTAssertEqual(paths.first, "/user/repos")
        XCTAssertTrue(queries.first?.contains("affiliation=owner") ?? false,
                      "the account scope must not re-list org repos: \(queries.first ?? "")")
        XCTAssertFalse(queries.first?.contains("organization_member") ?? true)
    }

    func test_organizationScopeListsThatOrgsRepositories() async throws {
        var paths: [String] = []
        let client = GitHubClient(token: "t", org: "Vorciu") { req in
            paths.append(req.url?.path ?? "")
            return (Data("[]".utf8), Self.ok(req))
        }

        _ = try await client.projects()

        XCTAssertEqual(paths.first, "/orgs/Vorciu/repos")
    }

    static func ok(_ req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}
