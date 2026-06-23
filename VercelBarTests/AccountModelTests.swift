import XCTest
@testable import VercelBar

final class AccountModelTests: XCTestCase {
    func test_provider_onlyVercelImplemented() {
        XCTAssertTrue(Provider.vercel.isImplemented)
        XCTAssertFalse(Provider.github.isImplemented)
        XCTAssertFalse(Provider.azureDevOps.isImplemented)
    }

    func test_provider_displayNames() {
        XCTAssertEqual(Provider.vercel.displayName, "Vercel")
        XCTAssertEqual(Provider.github.displayName, "GitHub")
        XCTAssertEqual(Provider.azureDevOps.displayName, "Azure DevOps")
    }

    func test_provider_codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Provider.vercel)
        XCTAssertEqual(try JSONDecoder().decode(Provider.self, from: data), .vercel)
    }
}
