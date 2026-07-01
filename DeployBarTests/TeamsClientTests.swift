import XCTest
@testable import DeployBar

final class TeamsClientTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: n, withExtension: "json")))
    }
    func test_teams_buildsAuthorizedRequest() async throws {
        var captured: URLRequest?
        let payload = try fixture("teams")
        let client = TeamsClient(token: "vca_X") { req in
            captured = req
            return (payload, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let teams = try await client.teams()
        XCTAssertFalse(teams.isEmpty)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer vca_X")
        XCTAssertTrue(captured!.url!.absoluteString.contains("/v2/teams"))
    }
    func test_user_decodes() async throws {
        let payload = try fixture("user")
        let client = UserClient(token: "vca_X") { req in
            (payload, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let u = try await client.user()
        XCTAssertFalse(u.username.isEmpty)
    }
    func test_unauthorizedThrows() async {
        let client = TeamsClient(token: "bad") { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.teams(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? VercelClientError, .unauthorized) }
    }
}
