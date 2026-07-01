import XCTest
@testable import DeployBar

final class TeamModelTests: XCTestCase {
    private func data(_ n: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: n, withExtension: "json")))
    }
    func test_decodesTeams() throws {
        let r = try JSONDecoder().decode(TeamsResponse.self, from: data("teams"))
        XCTAssertFalse(r.teams.isEmpty)
        XCTAssertTrue(r.teams.contains { $0.slug == "acme" })
        XCTAssertTrue(r.teams.allSatisfy { !$0.id.isEmpty })
    }
    func test_decodesUser() throws {
        let r = try JSONDecoder().decode(UserResponse.self, from: data("user"))
        XCTAssertFalse(r.user.username.isEmpty)
    }
    func test_userDecodesWithNullAvatar() throws {
        let json = #"{"user":{"username":"x","name":null,"email":null,"avatar":null}}"#
        let r = try JSONDecoder().decode(UserResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.user.username, "x")
        XCTAssertNil(r.user.avatar)
    }
}
