import XCTest
@testable import DeployBar

/// `AzureDevOpsClient` against an injected transport. JSON keys mirror a
/// live organization's responses recorded in the design spec.
final class AzureDevOpsClientTests: XCTestCase {

    /// Records requests; answers by path.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        var routes: [(matches: (URLRequest) -> Bool, status: Int, headers: [String: String], body: String)] = []
        func route(_ path: String, status: Int = 200, headers: [String: String] = [:], body: String) {
            routes.append(({ $0.url!.path.hasSuffix(path) }, status, headers, body))
        }
        func handle(_ req: URLRequest) -> (Data, URLResponse) {
            lock.withLock { requests.append(req) }
            let hit = routes.last { $0.matches(req) }
            let response = HTTPURLResponse(url: req.url!, statusCode: hit?.status ?? 404, httpVersion: nil,
                                           headerFields: hit?.headers ?? [:])!
            return (Data((hit?.body ?? "{}").utf8), response)
        }
    }

    private func client(_ server: Server, fanout: Int = 20) -> AzureDevOpsClient {
        AzureDevOpsClient(organization: "contoso", token: "tok", projectFanoutLimit: fanout) { server.handle($0) }
    }

    private static let projectsJSON = """
    {"count":2,"value":[
      {"id":"p1","name":"Shop","lastUpdateTime":"2026-09-28T10:00:00.123Z","state":"wellFormed","visibility":"private","url":"u"},
      {"id":"p2","name":"My Shop","lastUpdateTime":"2026-09-20T10:00:00Z","state":"wellFormed","visibility":"private","url":"u"}
    ]}
    """

    private static func build(id: Int, project: (String, String) = ("p1", "Shop"), status: String = "completed",
                               result: String? = "succeeded", repoType: String = "TfsGit",
                               repoName: String = "web", message: String? = "Fix the build") -> String {
        let resultJSON = result.map { "\"\($0)\"" } ?? "null"
        let trigger = message.map { #""triggerInfo":{"ci.message":"\#($0)","ci.sourceSha":"abc"},"# } ?? ""
        return """
        {"id":\(id),"buildNumber":"20260928.\(id)","status":"\(status)","result":\(resultJSON),
         "queueTime":"2026-09-28T10:00:0\(id % 10).1234567Z","startTime":"2026-09-28T10:00:10Z",
         "finishTime":"2026-09-28T10:05:00Z","sourceBranch":"refs/heads/main","sourceVersion":"abc\(id)",
         "definition":{"id":7,"name":"CI"},"reason":"individualCI",\(trigger)
         "repository":{"id":"r1","name":"\(repoName)","type":"\(repoType)"},
         "requestedFor":{"displayName":"Ada Lovelace","uniqueName":"ada@example.com","imageUrl":"https://x"},
         "project":{"id":"\(project.0)","name":"\(project.1)"},
         "_links":{"web":{"href":"https://dev.azure.com/contoso/\(project.0)/_build/results?buildId=\(id)"}}}
        """
    }

    // MARK: Auth and errors

    func test_sendsBasicAuthAndApiVersion() async throws {
        let server = Server()
        server.route("/_apis/git/repositories", body: #"{"value":[]}"#)
        _ = try await client(server).projects()
        let req = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Basic OnRvaw==")
        XCTAssertEqual(req.url?.host, "dev.azure.com")
        XCTAssertTrue(req.url!.query!.contains("api-version=7.1"))
    }

    /// Review focus 1: a rejected PAT gets an HTML sign-in page with 203.
    func test_rejectedTokenSignInPageIsUnauthorized() async {
        let server = Server()
        server.route("/_apis/git/repositories", status: 203, headers: ["Content-Type": "text/html"],
                     body: "<html>Sign in</html>")
        do { _ = try await client(server).projects(); XCTFail("expected unauthorized") }
        catch { XCTAssertEqual(error as? ProviderClientError, .unauthorized) }
    }

    func test_401IsUnauthorizedAnd429IsRateLimited() async {
        let server = Server()
        server.route("/_apis/git/repositories", status: 401, body: "")
        do { _ = try await client(server).projects(); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderClientError, .unauthorized) }
        server.route("/_apis/git/repositories", status: 429, headers: ["Retry-After": "30"], body: "")
        do { _ = try await client(server).projects(); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderClientError, .rateLimited(retryAfter: 30)) }
    }

    // MARK: Projects

    func test_repositoriesBecomeProjects() async throws {
        let server = Server()
        server.route("/_apis/git/repositories", body: """
        {"value":[
          {"id":"r1","name":"web","project":{"id":"p1","name":"Shop"},"defaultBranch":"refs/heads/main",
           "webUrl":"https://dev.azure.com/contoso/Shop/_git/web","isDisabled":false},
          {"id":"r2","name":"old","project":{"id":"p1","name":"Shop"},"isDisabled":true}
        ]}
        """)
        let projects = try await client(server).projects()
        XCTAssertEqual(projects.map(\.id), ["r1"], "disabled repositories are skipped")
        let web = try XCTUnwrap(projects.first)
        XCTAssertEqual(web.name, "Shop/web")
        XCTAssertEqual(web.repoName, "web")
        XCTAssertNil(web.repoOrg, "no GitHub link fallback for Azure Repos")
        XCTAssertEqual(web.repoType, "azureRepos")
        XCTAssertEqual(web.productionBranch, "main")
        XCTAssertEqual(web.repoURL?.absoluteString, "https://dev.azure.com/contoso/Shop/_git/web")
    }

    // MARK: Deployments

    func test_buildsBecomeDeployments() async throws {
        let server = Server()
        server.route("/_apis/projects", body: Self.projectsJSON)
        server.route("/p1/_apis/build/builds", body: #"{"value":[\#(Self.build(id: 2)),\#(Self.build(id: 1, result: "failed"))]}"#)
        server.route("/p2/_apis/build/builds", body: #"{"value":[]}"#)

        let deployments = try await client(server).deployments(limit: 100)

        XCTAssertEqual(deployments.map(\.uid), ["p1:2", "p1:1"], "newest first")
        let run = deployments[0]
        XCTAssertEqual(run.name, "Shop/web")
        XCTAssertEqual(run.state, .ready)
        XCTAssertEqual(deployments[1].state, .error)
        XCTAssertEqual(run.target, "main")
        XCTAssertEqual(run.commitRef, "main")
        XCTAssertEqual(run.commitSha, "abc2")
        XCTAssertEqual(run.commitMessage, "Fix the build")
        XCTAssertEqual(run.creatorUsername, "Ada Lovelace")
        XCTAssertNil(run.commitAuthorLogin, "ADO avatars need auth: initials only")
        XCTAssertEqual(run.webURL?.absoluteString, "https://dev.azure.com/contoso/p1/_build/results?buildId=2")
        XCTAssertEqual(run.commitURL?.absoluteString, "https://dev.azure.com/contoso/Shop/_git/web/commit/abc2")
        XCTAssertNotNil(run.ready)
        XCTAssertEqual(run.url, "")
    }

    /// Review focus 2.
    func test_commitURLEscapesProjectNames() {
        let url = AzureDevOpsClient.commitURL(organization: "contoso", project: "My Shop", repository: "web app", sha: "abc")
        XCTAssertEqual(url?.absoluteString, "https://dev.azure.com/contoso/My%20Shop/_git/web%20app/commit/abc")
    }

    func test_gitHubHostedRepositoryKeepsTheGitHubCommitLink() async throws {
        let server = Server()
        server.route("/_apis/projects", body: #"{"value":[{"id":"p1","name":"Shop"}]}"#)
        server.route("/p1/_apis/build/builds",
                     body: #"{"value":[\#(Self.build(id: 3, repoType: "GitHub", repoName: "acme/web"))]}"#)
        let deployments = try await client(server).deployments(limit: 10)
        let run = try XCTUnwrap(deployments.first)
        XCTAssertEqual(run.name, "Shop/acme/web")
        XCTAssertNil(run.commitURL)
        XCTAssertEqual(run.commitOrg, "acme")
        XCTAssertEqual(run.commitRepo, "web")
        XCTAssertEqual(LinkBuilder.commit(for: run)?.absoluteString, "https://github.com/acme/web/commit/abc3")
    }

    /// Review focus 3: a manual, unfinished run with no repository.
    func test_sparseBuildStillMaps() async throws {
        let server = Server()
        server.route("/_apis/projects", body: #"{"value":[{"id":"p1","name":"Shop"}]}"#)
        server.route("/p1/_apis/build/builds", body: """
        {"value":[{"id":9,"buildNumber":"9","status":"notStarted","queueTime":"2026-09-28T10:00:00Z",
                   "definition":{"id":7,"name":"Nightly"},"project":{"id":"p1","name":"Shop"}}]}
        """)
        let deployments = try await client(server).deployments(limit: 10)
        let run = try XCTUnwrap(deployments.first)
        XCTAssertEqual(run.state, .queued)
        XCTAssertEqual(run.name, "Shop/Nightly")
        XCTAssertEqual(run.commitMessage, "Nightly #9")
        XCTAssertNil(run.ready)
        XCTAssertNil(run.commitURL)
    }

    func test_stateMapping() {
        let cases: [(String?, String?, String)] = [
            ("inProgress", nil, "BUILDING"), ("cancelling", nil, "BUILDING"),
            ("notStarted", nil, "QUEUED"), ("postponed", nil, "QUEUED"),
            ("completed", "succeeded", "READY"), ("completed", "partiallySucceeded", "READY"),
            ("completed", "failed", "ERROR"), ("completed", "canceled", "CANCELED"),
            ("completed", "none", "UNKNOWN"), (nil, nil, "UNKNOWN"),
        ]
        for (status, result, expected) in cases {
            XCTAssertEqual(AzureDevOpsClient.state(status: status, result: result), expected, "\(String(describing: status)) \(String(describing: result))")
        }
    }

    func test_timestampsWithSevenFractionDigits() throws {
        let whole = try XCTUnwrap(AzureDevOpsClient.epochMs("2026-09-28T10:00:00Z"))
        let fractional = try XCTUnwrap(AzureDevOpsClient.epochMs("2026-09-28T10:00:00.1234567Z"))
        XCTAssertEqual(fractional - whole, 123.4567, accuracy: 0.001)
        XCTAssertNil(AzureDevOpsClient.epochMs("not a date"))
    }

    func test_buildFanOutIsCappedPerScope() async throws {
        let server = Server()
        let projects = (0..<25).map { #"{"id":"p\#($0)","name":"P\#($0)","lastUpdateTime":"2026-09-\#(10 + $0 % 18)T00:00:00Z"}"# }
        server.route("/_apis/projects", body: #"{"value":[\#(projects.joined(separator: ","))]}"#)
        server.routes.append(({ $0.url!.path.hasSuffix("/_apis/build/builds") }, 200, [:], #"{"value":[]}"#))
        _ = try await client(server).deployments(limit: 100)
        XCTAssertEqual(server.requests.filter { $0.url!.path.hasSuffix("/_apis/build/builds") }.count, 20)
    }

    func test_oneFailingProjectDoesNotBlankTheOrganization() async throws {
        let server = Server()
        server.route("/_apis/projects", body: Self.projectsJSON)
        server.route("/p1/_apis/build/builds", body: #"{"value":[\#(Self.build(id: 1))]}"#)
        server.routes.append(({ $0.url!.path.contains("/p2/") }, 500, [:], ""))
        let runs = try await client(server).deployments(limit: 10)
        XCTAssertEqual(runs.map(\.uid), ["p1:1"])
    }

    func test_throttlingWithNothingBackIsReported() async {
        let server = Server()
        server.route("/_apis/projects", body: #"{"value":[{"id":"p1","name":"Shop"}]}"#)
        server.route("/p1/_apis/build/builds", status: 429, headers: ["Retry-After": "60"], body: "")
        do { _ = try await client(server).deployments(limit: 10); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderClientError, .rateLimited(retryAfter: 60)) }
    }

    // MARK: Re-reads and reports

    func test_refreshReadsByIdOncePerProject() async throws {
        let server = Server()
        server.route("/p1/_apis/build/builds", body: #"{"value":[\#(Self.build(id: 1)),\#(Self.build(id: 2))]}"#)
        server.route("/p2/_apis/build/builds", body: #"{"value":[\#(Self.build(id: 3, project: ("p2", "My Shop")))]}"#)
        let stale = [
            Deployment(uid: "p1:1", name: "Shop/web", stateRaw: "BUILDING", url: "", createdAt: 1),
            Deployment(uid: "p1:2", name: "Shop/web", stateRaw: "BUILDING", url: "", createdAt: 1),
            Deployment(uid: "p2:3", name: "My Shop/web", stateRaw: "QUEUED", url: "", createdAt: 1),
        ]
        let fresh = try await client(server).refreshed(stale)
        XCTAssertEqual(Set(fresh.map(\.uid)), ["p1:1", "p1:2", "p2:3"])
        let queries = server.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)! }
        XCTAssertEqual(queries.count, 2)
        let ids = queries.compactMap { $0.queryItems?.first { $0.name == "buildIds" }?.value }.sorted()
        XCTAssertEqual(ids, ["1,2", "3"])
    }

    func test_failureReportListsFailedTasksAndTheLogTail() async throws {
        let server = Server()
        server.route("/p1/_apis/build/builds/5/timeline", body: """
        {"records":[
          {"id":"s","type":"Stage","name":"Build","result":"failed","order":1},
          {"id":"t1","parentId":"j","type":"Task","name":"Install","result":"succeeded","order":1},
          {"id":"t2","parentId":"j","type":"Task","name":"Compile","result":"failed","order":2,
           "log":{"id":12,"type":"Container","url":"u"},
           "issues":[{"type":"error","category":"General","message":"error CS1002: ; expected"},
                     {"type":"warning","category":"General","message":"noise"}]}
        ]}
        """)
        server.route("/p1/_apis/build/builds/5/logs/12", headers: ["Content-Type": "text/plain"],
                     body: "line 1\nline 2\n##[error]Process completed with exit code 1.")
        let failed = Deployment(uid: "p1:5", name: "Shop/web", stateRaw: "ERROR", url: "", createdAt: 1,
                                commitRef: "main", commitMessage: "Fix the build",
                                webURL: URL(string: "https://dev.azure.com/contoso/p1/_build/results?buildId=5"))
        let report = try await client(server).failureReport(for: failed)
        XCTAssertTrue(report.hasPrefix("Azure DevOps run failed"))
        XCTAssertTrue(report.contains("Failed task: Compile"))
        XCTAssertTrue(report.contains("✗ error CS1002: ; expected"))
        XCTAssertFalse(report.contains("noise"), "warnings are not failures")
        XCTAssertFalse(report.contains("Failed task: Install"))
        XCTAssertTrue(report.contains("--- Task log (tail) ---"))
        XCTAssertTrue(report.contains("exit code 1"))
        let logRequest = try XCTUnwrap(server.requests.first { $0.url!.path.hasSuffix("/logs/12") })
        XCTAssertEqual(logRequest.value(forHTTPHeaderField: "Accept"), "text/plain")
    }

    /// A job can fail before any task runs (no agent, job condition,
    /// infrastructure timeout); the report must fall back to failed jobs.
    func test_failureReportFallsBackToFailedJobWhenNoTaskFailed() async throws {
        let server = Server()
        server.route("/p1/_apis/build/builds/6/timeline", body: """
        {"records":[
          {"id":"s","type":"Stage","name":"Build","result":"failed","order":1},
          {"id":"j","type":"Job","name":"Build job","result":"failed","order":1,
           "log":{"id":21,"type":"Container","url":"u"},
           "issues":[{"type":"error","category":"General","message":"No agent found in pool Default"}]}
        ]}
        """)
        server.route("/p1/_apis/build/builds/6/logs/21", headers: ["Content-Type": "text/plain"],
                     body: "##[error]No agent found in pool Default")
        let failed = Deployment(uid: "p1:6", name: "Shop/web", stateRaw: "ERROR", url: "", createdAt: 1,
                                commitRef: "main", commitMessage: "Fix the build",
                                webURL: URL(string: "https://dev.azure.com/contoso/p1/_build/results?buildId=6"))
        let report = try await client(server).failureReport(for: failed)
        XCTAssertTrue(report.contains("Failed job: Build job"))
        XCTAssertTrue(report.contains("✗ No agent found in pool Default"))
        let logRequest = try XCTUnwrap(server.requests.first { $0.url!.path.hasSuffix("/logs/21") })
        XCTAssertEqual(logRequest.value(forHTTPHeaderField: "Accept"), "text/plain")
    }

    func test_authenticatedNameComesFromConnectionData() async throws {
        let server = Server()
        server.route("/_apis/connectionData", body: #"{"authenticatedUser":{"id":"u1","providerDisplayName":"Ada Lovelace"}}"#)
        let name = try await client(server).authenticatedName()
        XCTAssertEqual(name, "Ada Lovelace")
        XCTAssertFalse(server.requests[0].url!.query?.contains("api-version") ?? false,
                       "connectionData rejects api-version 7.1")
    }
}
