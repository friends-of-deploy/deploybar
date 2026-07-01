import XCTest
@testable import DeployBar

final class ScopeResolverTests: XCTestCase {
    func test_personalWhenNoTeam() async {
        let name = await ScopeResolver.scopeName(credentials: .init(token: "x", teamId: nil)) { _ in
            XCTFail("should not fetch"); return (Data(), URLResponse())
        }
        XCTAssertEqual(name, "personal")
    }
    func test_resolvesSlugFromTeamId() async {
        let name = await ScopeResolver.scopeName(credentials: .init(token: "x", teamId: "team_abc")) { req in
            XCTAssertTrue(req.url!.absoluteString.contains("team_abc"))
            return (Data(#"{"slug":"acme","name":"acme"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(name, "acme")
    }
    func test_fallsBackToTeamIdOnFailure() async {
        let name = await ScopeResolver.scopeName(credentials: .init(token: "x", teamId: "team_abc")) { _ in
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(name, "team_abc")
    }
}
