import XCTest

final class ScaffoldTests: XCTestCase {
    func test_fixturesAreBundled() throws {
        XCTAssertNotNil(Bundle(for: Self.self).url(forResource: "deployments", withExtension: "json"))
        XCTAssertNotNil(Bundle(for: Self.self).url(forResource: "projects", withExtension: "json"))
    }
}
