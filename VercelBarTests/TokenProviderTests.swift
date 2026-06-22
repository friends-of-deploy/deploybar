import XCTest
@testable import VercelBar

final class TokenProviderTests: XCTestCase {
    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_readsTokenAndTeam() throws {
        let dir = try tmpDir()
        try #"{"token":"vca_TEST"}"#.write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try #"{"currentTeam":"team_abc"}"#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let p = TokenProvider(configDirectory: dir)
        let creds = try p.credentials()
        XCTAssertEqual(creds.token, "vca_TEST")
        XCTAssertEqual(creds.teamId, "team_abc")
    }

    func test_missingAuthThrowsNotLoggedIn() throws {
        let dir = try tmpDir()
        let p = TokenProvider(configDirectory: dir)
        XCTAssertThrowsError(try p.credentials()) { error in
            XCTAssertEqual(error as? TokenError, .notLoggedIn)
        }
    }

    func test_teamOptionalWhenPersonalScope() throws {
        let dir = try tmpDir()
        try #"{"token":"vca_TEST"}"#.write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let p = TokenProvider(configDirectory: dir)
        XCTAssertNil(try p.credentials().teamId)
    }

    func test_emptyTokenThrowsNotLoggedIn() throws {
        let dir = try tmpDir()
        try #"{"token":""}"#.write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let p = TokenProvider(configDirectory: dir)
        XCTAssertThrowsError(try p.credentials()) { error in
            XCTAssertEqual(error as? TokenError, .notLoggedIn)
        }
    }

    func test_malformedAuthJsonThrowsNotLoggedIn() throws {
        let dir = try tmpDir()
        try "NOTJSON".write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let p = TokenProvider(configDirectory: dir)
        XCTAssertThrowsError(try p.credentials()) { error in
            XCTAssertEqual(error as? TokenError, .notLoggedIn)
        }
    }

    func test_authJsonWithoutTokenKeyThrowsNotLoggedIn() throws {
        let dir = try tmpDir()
        try #"{"user":"foo"}"#.write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let p = TokenProvider(configDirectory: dir)
        XCTAssertThrowsError(try p.credentials()) { error in
            XCTAssertEqual(error as? TokenError, .notLoggedIn)
        }
    }
}
