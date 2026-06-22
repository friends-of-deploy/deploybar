import XCTest
@testable import VercelBar

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
