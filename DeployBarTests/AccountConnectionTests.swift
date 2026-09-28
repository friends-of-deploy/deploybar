import XCTest
@testable import DeployBar

@MainActor
final class AccountConnectionTests: XCTestCase {

    private func makeAccounts() -> AccountStore {
        AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                     credentials: InMemoryCredentialStore(),
                     detectCLI: { false }, detectGitHubCLI: { false })
    }

    /// A provider whose identity echoes the organization it was asked about.
    private struct EchoIntegration: ProviderIntegration {
        let provider: Provider
        var pollCost: PollCostModel { GitHubIntegration().pollCost }
        var presentation: ProviderPresentation { GitHubIntegration().presentation }
        func identity(for account: Account, using credential: ResolvedCredential) async throws -> AccountIdentity {
            if account.organization == nil && provider == .azureDevOps { throw AccountValidationError.organizationRequired }
            return AccountIdentity(username: "user@\(account.organization ?? "none")")
        }
        func organizations(for account: Account, using credential: ResolvedCredential) async throws -> [Team] { [] }
        @MainActor func client(for scope: Scope, using credential: ResolvedCredential) -> DeploymentProviderClient? { nil }
        func failureReport(for deployment: Deployment, teamId: String?, using credential: ResolvedCredential) async throws -> String { "" }
    }

    func test_defaultValidatorAsksTheInjectedRegistry() async {
        let accounts = makeAccounts()
        let connection = AccountConnectionStore(registry: ProviderRegistry([EchoIntegration(provider: .azureDevOps)]))
        connection.provider = .azureDevOps
        connection.organization = "  contoso \n"
        connection.token = "pat"
        let account = await connection.connect(to: accounts)
        XCTAssertEqual(account?.label, "user@contoso")
        XCTAssertEqual(account?.organization, "contoso", "trimmed and stored")
        XCTAssertEqual(accounts.token(for: account!), "pat")
        XCTAssertEqual(connection.organization, "", "cleared after success")
    }

    func test_orgScopedTokenWithoutOrganizationAsksForIt() async {
        let accounts = makeAccounts()
        let connection = AccountConnectionStore(registry: ProviderRegistry([EchoIntegration(provider: .azureDevOps)]))
        connection.provider = .azureDevOps
        connection.token = "pat"
        let account = await connection.connect(to: accounts)
        XCTAssertNil(account)
        XCTAssertEqual(connection.errorMessage,
                       "This token only works inside one organization. Enter its name above.")
        XCTAssertTrue(accounts.accounts.isEmpty)
    }

    /// Review focus 4.
    func test_changingProviderClearsTheOrganization() async {
        let accounts = makeAccounts()
        var seen: Account?
        let connection = AccountConnectionStore(validate: { account, _ in seen = account; return "u" })
        connection.provider = .azureDevOps
        connection.organization = "contoso"
        connection.provider = .github
        connection.token = "t"
        let account = await connection.connect(to: accounts)
        XCTAssertEqual(connection.organization, "")
        XCTAssertNil(seen?.organization)
        XCTAssertNil(account?.organization)
    }
}
