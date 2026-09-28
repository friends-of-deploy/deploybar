import XCTest
@testable import DeployBar

@MainActor
final class AzureDevOpsIntegrationTests: XCTestCase {

    private func respond(_ status: Int, _ body: String, record: ((URLRequest) -> Void)? = nil) -> ResolvedCredential {
        ResolvedCredential(token: "pat", transport: { req in
            record?(req)
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }

    private func account(organization: String?) -> Account {
        Account(id: UUID(), provider: .azureDevOps, label: "ADO", source: .keychain(account: "k"),
                organization: organization)
    }

    // MARK: Identity

    func test_identityWithAnOrganizationUsesConnectionData() async throws {
        var url: URL?
        let identity = try await AzureDevOpsIntegration().identity(
            for: account(organization: "contoso"),
            using: respond(200, #"{"authenticatedUser":{"providerDisplayName":"Ada"}}"#) { url = $0.url })
        XCTAssertEqual(identity.username, "Ada")
        XCTAssertEqual(url?.host, "dev.azure.com")
        XCTAssertEqual(url?.path, "/contoso/_apis/connectionData")
    }

    func test_identityWithoutAnOrganizationUsesTheProfile() async throws {
        var url: URL?
        let identity = try await AzureDevOpsIntegration().identity(
            for: account(organization: nil),
            using: respond(200, #"{"id":"m1","displayName":"Ada"}"#) { url = $0.url })
        XCTAssertEqual(identity.username, "Ada")
        XCTAssertEqual(url?.host, "app.vssps.visualstudio.com")
    }

    /// An org-scoped PAT is refused by the global profile API with 401.
    func test_orgScopedTokenWithoutOrganizationNeedsOne() async {
        do {
            _ = try await AzureDevOpsIntegration().identity(for: account(organization: nil), using: respond(401, ""))
            XCTFail("expected organizationRequired")
        } catch { XCTAssertEqual(error as? AccountValidationError, .organizationRequired) }
    }

    /// A bad PAT is a bad PAT, not a missing organization.
    func test_rejectedTokenIsUnauthorizedEvenWithoutOrganization() async {
        do {
            _ = try await AzureDevOpsIntegration().identity(for: account(organization: nil), using: respond(203, "<html/>"))
            XCTFail("expected unauthorized")
        } catch { XCTAssertEqual(error as? ProviderClientError, .unauthorized) }
    }

    // MARK: Organizations

    func test_enteredOrganizationIsTheOnlyOneAndCostsNoRequest() async throws {
        let failing = ResolvedCredential(token: "pat", transport: { _ in
            XCTFail("no request expected"); throw URLError(.badURL)
        })
        let orgs = try await AzureDevOpsIntegration().organizations(for: account(organization: "contoso"), using: failing)
        XCTAssertEqual(orgs.map(\.id), ["contoso"])
    }

    func test_discoveredOrganizationsComeFromTheProfileAndAccounts() async throws {
        let credential = ResolvedCredential(token: "pat", transport: { req in
            let body = req.url!.path.hasSuffix("/profiles/me")
                ? #"{"id":"m1","displayName":"Ada"}"#
                : #"{"count":2,"value":[{"accountId":"a2","accountName":"zeta"},{"accountId":"a1","accountName":"Alpha"}]}"#
            if req.url!.path.hasSuffix("/accounts") {
                XCTAssertTrue(req.url!.query!.contains("memberId=m1"))
            }
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let orgs = try await AzureDevOpsIntegration().organizations(for: account(organization: nil), using: credential)
        XCTAssertEqual(orgs.map(\.id), ["Alpha", "zeta"])
    }

    // MARK: Clients, cost, presentation

    func test_clientIsPerOrganizationAndNothingWithoutOne() throws {
        let acct = account(organization: "contoso")
        let integration = AzureDevOpsIntegration()
        XCTAssertNil(integration.client(for: Scope(account: acct, teamId: nil, teamName: nil), using: .plain("pat")))
        let client = try XCTUnwrap(integration.client(for: Scope(account: acct, teamId: "contoso", teamName: "contoso"),
                                                      using: .plain("pat")) as? AzureDevOpsClient)
        XCTAssertEqual(client.organization, "contoso")
    }

    func test_costAndShape() {
        let integration = AzureDevOpsIntegration()
        XCTAssertFalse(integration.hasAccountScope)
        XCTAssertEqual(integration.pollCost.hourlyLimit, 5000)
        XCTAssertEqual(integration.pollCost.maxRequestsPerScope, 22)
        let scope = Scope(account: account(organization: "o"), teamId: "o", teamName: "o")
        XCTAssertEqual(integration.pollCost.estimatedCost(scope, 3), 22)
        XCTAssertEqual(integration.pollCost.sharedReserve([scope]), 0)
        XCTAssertTrue(integration.pollCost.metersOffCyclePolls)
        XCTAssertTrue(integration.pollCost.reservesInProgressRefreshes)
        XCTAssertEqual(integration.presentation.vocabulary, .ciRuns)
        XCTAssertEqual(integration.presentation.accountFields, [.organization])
        XCTAssertNil(integration.presentation.ownerLabel(AccountIdentity(username: "Ada")))
    }

    /// Review focus 2.
    func test_menuLinksEscapeNames() {
        let project = Project(id: "r1", name: "My Shop/web", repoName: "web",
                              repoURL: URL(string: "https://dev.azure.com/contoso/My%20Shop/_git/web"))
        let links = AzureDevOpsIntegration().presentation.projectMenuLinks(project, "contoso")
        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://dev.azure.com/contoso/My%20Shop/_build",
            "https://dev.azure.com/contoso/My%20Shop/_git/web/pullrequests",
            "https://dev.azure.com/contoso/My%20Shop/_settings/repositories?repo=r1",
        ])
        XCTAssertEqual(links.map { String(localized: $0.title) }, ["Pipelines", "Pull requests", "Repository settings"])
    }
}
