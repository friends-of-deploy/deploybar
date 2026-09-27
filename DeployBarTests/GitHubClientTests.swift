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

    // MARK: - refreshed(_:)

    /// A run is re-read by id — one request, no repository listing — and keeps
    /// its repository identity while its state moves on.
    func test_refreshed_rereadsRunsById() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.url!.path, "/repos/acme/web/actions/runs/99")
            return (200, """
            {"id":99,"name":"CI","display_title":"Earlier run","head_branch":"main","head_sha":"def456",
             "status":"completed","conclusion":"success","html_url":"https://github.com/acme/web/actions/runs/99",
             "created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:03:00Z",
             "run_started_at":"2024-01-01T00:00:05Z","actor":{"login":"octocat","avatar_url":null},
             "head_commit":{"message":"m"}}
            """)
        }
        let stale = Deployment(uid: "99", name: "acme/web", stateRaw: "BUILDING", url: "",
                               createdAt: 1_704_067_200_000, commitOrg: "acme", commitRepo: "web")

        let fresh = try await client.refreshed([stale])

        XCTAssertEqual(fresh.map(\.uid), ["99"])
        XCTAssertEqual(fresh[0].state, .ready)
        XCTAssertEqual(fresh[0].name, "acme/web")
        XCTAssertEqual(fresh[0].commitOrg, "acme")
        XCTAssertEqual(fresh[0].commitRepo, "web")
        XCTAssertNotNil(fresh[0].ready)
    }

    /// One unreadable run is skipped, not fatal — its row keeps its last state.
    func test_refreshed_skipsRunsThatFail() async throws {
        let client = makeClient { _ in (404, "{}") }
        let stale = Deployment(uid: "1", name: "acme/web", stateRaw: "BUILDING", url: "", createdAt: 1)

        let fresh = try await client.refreshed([stale])

        XCTAssertTrue(fresh.isEmpty)
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

        XCTAssertEqual(paths.first, "/user/repos")
    }


    func test_orgScopeOnlyIncludesAccessibleRepositoriesOwnedByThatOrg() async throws {
        let client = GitHubClient(token: "fine-grained", org: "acme") { req in
            let json = req.url!.path == "/user/repos" ? Self.reposJSON : "[]"
            return (Data(json.utf8), Self.ok(req))
        }
        let projects = try await client.projects()
        XCTAssertEqual(projects.map(\.id), ["acme/web", "acme/api"])
        let other = GitHubClient(token: "fine-grained", org: "unrelated") { req in
            (Data(Self.reposJSON.utf8), Self.ok(req))
        }
        let unrelated = try await other.projects()
        XCTAssertTrue(unrelated.isEmpty)
    }


    private actor RequestCounter {
        var count = 0
        func increment() { count += 1 }
    }

    func test_worstCaseScopeCostsFortyRequests() async throws {
        let requests = RequestCounter()
        let entry = #"{"id":1,"name":"repo","full_name":"acme/repo","owner":{"login":"acme"},"html_url":"https://github.com/acme/repo"}"#
        let page = Data(("[" + Array(repeating: entry, count: 100).joined(separator: ",") + "]").utf8)
        let client = GitHubClient(token: "t", org: "acme") { req in
            await requests.increment()
            return (req.url!.path == "/user/repos" ? page : Data(#"{"workflow_runs":[]}"#.utf8), Self.ok(req))
        }
        _ = try await client.projects()
        _ = try await client.deployments(limit: 100)
        let requestCount = await requests.count
        XCTAssertEqual(requestCount, 40)
        XCTAssertLessThanOrEqual(requestCount, GitHubClient.maxRequestsPerScope)
    }

    // MARK: - Shared organization listing

    /// Records each `/user/repos` request's query, so a test can count listings.
    private actor ListingLog {
        private(set) var queries: [String] = []
        func add(_ query: String) { queries.append(query) }
    }

    /// Serves `reposJSON` (two `acme` repositories) for listings, with the
    /// status `listingStatus` picks, and an empty run list for everything else.
    private func listingClient(org: String?, token: String = "t",
                               listing: GitHubRepositoryListing, log: ListingLog,
                               listingStatus: @escaping @Sendable () async -> Int = { 200 }) -> GitHubClient {
        GitHubClient(token: token, org: org, listing: listing) { req in
            guard req.url!.path == "/user/repos" else {
                return (Data(#"{"workflow_runs":[]}"#.utf8), Self.ok(req))
            }
            await log.add(req.url!.query ?? "")
            let status = await listingStatus()
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data((status == 200 ? Self.reposJSON : "{}").utf8), resp)
        }
    }

    func test_organizationScopesShareOneListing() async throws {
        let listing = GitHubRepositoryListing()
        let log = ListingLog()
        let acme = listingClient(org: "acme", listing: listing, log: log)
        let beta = listingClient(org: "beta", listing: listing, log: log)

        async let acmeProjects = acme.projects()
        async let acmeRuns = acme.deployments(limit: 100)
        async let betaProjects = beta.projects()
        async let betaRuns = beta.deployments(limit: 100)
        let (ap, _, bp, _) = try await (acmeProjects, acmeRuns, betaProjects, betaRuns)

        XCTAssertEqual(ap.map(\.id), ["acme/web", "acme/api"])
        XCTAssertTrue(bp.isEmpty, "another owner's repositories stay out of the scope")
        let listings = await log.queries.count
        XCTAssertEqual(listings, 1, "two organizations, projects and runs each: one listing")
    }

    func test_resetStartsAFreshListing() async throws {
        let listing = GitHubRepositoryListing()
        let log = ListingLog()
        let client = listingClient(org: "acme", listing: listing, log: log)

        _ = try await client.projects()
        await listing.reset()
        _ = try await client.projects()

        let listings = await log.queries.count
        XCTAssertEqual(listings, 2, "a new tick must see new pushes")
    }

    func test_failedListingIsFetchedAgain() async throws {
        let listing = GitHubRepositoryListing()
        let log = ListingLog()
        let attempts = RequestCounter()
        let client = listingClient(org: "acme", listing: listing, log: log) {
            await attempts.increment()
            return await attempts.count == 1 ? 500 : 200
        }

        do {
            _ = try await client.projects()
            XCTFail("the first listing fails")
        } catch {}
        let projects = try await client.projects()

        XCTAssertEqual(projects.map(\.id), ["acme/web", "acme/api"],
                       "a failed listing must not be served for the rest of the tick")
    }

    /// While GitHub throttles, re-listing for each wave of organizations only
    /// digs the hole deeper: the rest of the tick gets the same error for free.
    func test_rateLimitedListingIsKeptUntilTheNextTick() async throws {
        let listing = GitHubRepositoryListing()
        let log = ListingLog()
        let client = GitHubClient(token: "t", org: "acme", listing: listing) { req in
            guard req.url!.path == "/user/repos" else {
                return (Data(#"{"workflow_runs":[]}"#.utf8), Self.ok(req))
            }
            await log.add(req.url!.query ?? "")
            let throttled = await log.queries.count == 1
            let resp = HTTPURLResponse(url: req.url!, statusCode: throttled ? 403 : 200, httpVersion: nil,
                                       headerFields: throttled ? ["x-ratelimit-remaining": "0"] : nil)!
            return (Data((throttled ? "{}" : Self.reposJSON).utf8), resp)
        }

        for attempt in 1...2 {
            do {
                _ = try await client.projects()
                XCTFail("attempt \(attempt) must report the throttle")
            } catch ProviderClientError.rateLimited {
            } catch {
                XCTFail("attempt \(attempt): expected rateLimited, got \(error)")
            }
        }
        let throttledListings = await log.queries.count
        XCTAssertEqual(throttledListings, 1, "a throttled listing is not re-requested within the tick")

        await listing.reset()
        let projects = try await client.projects()
        XCTAssertEqual(projects.map(\.id), ["acme/web", "acme/api"], "the next tick lists again")
    }

    func test_differentTokensDoNotShareAListing() async throws {
        let listing = GitHubRepositoryListing()
        let log = ListingLog()

        _ = try await listingClient(org: "acme", token: "one", listing: listing, log: log).projects()
        _ = try await listingClient(org: "acme", token: "two", listing: listing, log: log).projects()

        let listings = await log.queries.count
        XCTAssertEqual(listings, 2, "a rotated or different token sees its own repositories")
    }

    func test_personalScopeKeepsItsOwnerOnlyListing() async throws {
        let listing = GitHubRepositoryListing()
        let log = ListingLog()

        _ = try await listingClient(org: "acme", listing: listing, log: log).projects()
        _ = try await listingClient(org: nil, listing: listing, log: log).projects()

        let queries = await log.queries
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries[1].contains("affiliation=owner"),
                      "the personal scope must not reuse the organizations' listing: \(queries[1])")
    }

    static func ok(_ req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}
