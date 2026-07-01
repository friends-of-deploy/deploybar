import XCTest
@testable import DeployBar

final class VercelClientTests: XCTestCase {
    private func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
    private func ok(_ url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    func test_deployments_buildsAuthorizedRequestWithTeam() async throws {
        var captured: URLRequest?
        let payload = try data("deployments")
        let client = VercelClient(credentials: .init(token: "vca_X", teamId: "team_abc")) { req in
            captured = req
            return (payload, self.ok(req.url!))
        }
        let deps = try await client.deployments(limit: 100)
        XCTAssertFalse(deps.isEmpty)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer vca_X")
        let urlString = try XCTUnwrap(captured?.url?.absoluteString)
        XCTAssertTrue(urlString.contains("/v6/deployments"))
        XCTAssertTrue(urlString.contains("limit=100"))
        XCTAssertTrue(urlString.contains("teamId=team_abc"))
    }

    func test_projects_followsPaginationCursorAcrossPages() async throws {
        // Page 1 returns one project + a `next` cursor; page 2 returns another with
        // next=null. The client must follow the cursor and merge both pages.
        let page1 = #"{"projects":[{"id":"prj_1","name":"alpha"}],"pagination":{"next":1700000000000}}"#
        let page2 = #"{"projects":[{"id":"prj_2","name":"beta"}],"pagination":{"next":null}}"#
        var capturedURLs: [String] = []
        let client = VercelClient(credentials: .init(token: "vca_X", teamId: nil)) { req in
            let urlString = req.url!.absoluteString
            capturedURLs.append(urlString)
            let body = urlString.contains("until=") ? page2 : page1
            return (Data(body.utf8), self.ok(req.url!))
        }
        let projects = try await client.projects()
        XCTAssertEqual(projects.map(\.id), ["prj_1", "prj_2"])   // both pages merged
        XCTAssertEqual(capturedURLs.count, 2)                    // exactly two requests
        XCTAssertFalse(capturedURLs[0].contains("until="))       // first page: no cursor
        XCTAssertTrue(capturedURLs[1].contains("until=1700000000000"))  // second page: cursor passed
    }

    func test_projects_stopsAfterSinglePageWhenNextIsNil() async throws {
        let onePage = #"{"projects":[{"id":"prj_1","name":"alpha"}],"pagination":{"next":null}}"#
        var requestCount = 0
        let client = VercelClient(credentials: .init(token: "vca_X", teamId: nil)) { req in
            requestCount += 1
            return (Data(onePage.utf8), self.ok(req.url!))
        }
        let projects = try await client.projects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(requestCount, 1)   // no extra request when next is nil
    }

    func test_projects_decodesAndOmitsTeamWhenNil() async throws {
        var captured: URLRequest?
        let payload = try data("projects")
        let client = VercelClient(credentials: .init(token: "vca_X", teamId: nil)) { req in
            captured = req
            return (payload, self.ok(req.url!))
        }
        let projects = try await client.projects()
        XCTAssertFalse(projects.isEmpty)
        XCTAssertFalse(try XCTUnwrap(captured?.url?.absoluteString).contains("teamId="))
    }

    func test_unauthorizedThrows() async {
        let client = VercelClient(credentials: .init(token: "bad", teamId: nil)) { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.deployments(limit: 10); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? VercelClientError, .unauthorized) }
    }

    func test_serverErrorThrowsHttp() async {
        let client = VercelClient(credentials: .init(token: "x", teamId: nil)) { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.projects(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? VercelClientError, .http(500)) }
    }

    func test_forbiddenMapsToUnauthorized() async {
        let client = VercelClient(credentials: .init(token: "x", teamId: nil)) { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.deployments(limit: 5); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? VercelClientError, .unauthorized) }
    }

    func test_networkErrorIsRethrown() async {
        let client = VercelClient(credentials: .init(token: "x", teamId: nil)) { _ in
            throw URLError(.notConnectedToInternet)
        }
        do { _ = try await client.projects(); XCTFail("expected throw") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }
}

extension VercelClientTests {
    func test_vercelClient_conformsToProviderProtocol() async throws {
        let client: DeploymentProviderClient = VercelClient(
            credentials: VercelCredentials(token: "x", teamId: nil)
        ) { req in
            let isDeployments = req.url!.path.contains("deployments")
            let body = isDeployments ? #"{"deployments":[]}"# : #"{"projects":[]}"#
            return (Data(body.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let deps = try await client.deployments(limit: 5)
        let projs = try await client.projects()
        XCTAssertTrue(deps.isEmpty)
        XCTAssertTrue(projs.isEmpty)
    }
}
