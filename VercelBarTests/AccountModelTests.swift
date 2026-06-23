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

extension AccountModelTests {
    func test_account_codableRoundTrip() throws {
        let acct = Account(id: UUID(), provider: .vercel, label: "alice",
                           source: .keychain(account: "kc-1"))
        let data = try JSONEncoder().encode(acct)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: data), acct)
    }

    func test_account_cliIsReadOnly() {
        let cli = Account.vercelCLI(id: UUID(), label: "from CLI")
        XCTAssertTrue(cli.isReadOnly)
        XCTAssertEqual(cli.source, .vercelCLI)
        XCTAssertEqual(cli.provider, .vercel)
    }

    func test_account_keychainNotReadOnly() {
        let acct = Account(id: UUID(), provider: .vercel, label: "bob",
                           source: .keychain(account: "kc-2"))
        XCTAssertFalse(acct.isReadOnly)
    }
}
