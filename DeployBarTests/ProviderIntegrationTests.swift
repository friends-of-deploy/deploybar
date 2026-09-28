import XCTest
@testable import DeployBar

@MainActor
final class ProviderIntegrationTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    /// Serves `body` for every request and checks the bearer token.
    private func credential(_ token: String, body: Data) -> ResolvedCredential {
        ResolvedCredential(token: token, transport: { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    private let vercelAccount = Account(id: UUID(), provider: .vercel, label: "V", source: .keychain(account: "v"))
    private let githubAccount = Account(id: UUID(), provider: .github, label: "G", source: .keychain(account: "g"))

    // MARK: Registry

    func test_liveRegistryOffersVercelAndGitHubOnly() {
        let registry = ProviderRegistry.live()
        XCTAssertEqual(registry.all.map(\.provider), [.vercel, .github])
        XCTAssertTrue(registry.isAvailable(.vercel))
        XCTAssertTrue(registry.isAvailable(.github))
        XCTAssertFalse(registry.isAvailable(.azureDevOps))
        XCTAssertNil(registry.integration(for: .azureDevOps))
    }

    // MARK: Vercel

    func test_vercelIdentityIsTheUsername() async throws {
        let identity = try await VercelIntegration().identity(for: vercelAccount, using: credential("t", body: fixture("user")))
        XCTAssertFalse(identity.username.isEmpty)
    }

    func test_vercelOrganizationsAreTeams() async throws {
        let teams = try await VercelIntegration().organizations(for: vercelAccount,
                                                                using: credential("t", body: fixture("teams")))
        XCTAssertTrue(teams.contains { $0.slug == "acme" })
    }

    func test_vercelClientTargetsTheScopeTeam() throws {
        let scope = Scope(account: vercelAccount, teamId: "team_1", teamName: nil)
        let client = try XCTUnwrap(VercelIntegration().client(for: scope, using: .plain("t")) as? VercelClient)
        XCTAssertEqual(client.credentials.teamId, "team_1")
        XCTAssertEqual(client.credentials.token, "t")
    }

    func test_vercelFailureReportUsesBuildEvents() async throws {
        let deployment = Deployment(uid: "dpl_1", name: "web", stateRaw: "ERROR", url: "web.vercel.app", createdAt: 1)
        let report = try await VercelIntegration().failureReport(for: deployment, teamId: nil,
                                                                 using: credential("t", body: Data("[]".utf8)))
        XCTAssertTrue(report.hasPrefix("Vercel deployment failed"))
    }

    func test_vercelCostIsFlat() {
        let cost = VercelIntegration().pollCost
        let scope = Scope(account: vercelAccount, teamId: "t1", teamName: nil)
        XCTAssertEqual(cost.hourlyLimit, 20000)
        XCTAssertEqual(cost.maxRequestsPerScope, 2)
        XCTAssertEqual(cost.estimatedCost(scope, 50), 2)
        XCTAssertEqual(cost.sharedReserve([scope]), 0)
        XCTAssertFalse(cost.metersOffCyclePolls)
        XCTAssertFalse(cost.reservesInProgressRefreshes)
    }

    /// Same four links, in the same order, as the hand-written ⋯ menu had.
    func test_vercelMenuLinksMatchTheOldMenu() {
        let menu = VercelIntegration().presentation.projectMenuLinks
        let withAnalytics = menu(Project(id: "p", name: "web", hasAnalytics: true), "acme")
        XCTAssertEqual(withAnalytics.map(\.url.absoluteString), [
            "https://vercel.com/acme/web/settings/environment-variables",
            "https://vercel.com/acme/web/analytics",
            "https://vercel.com/acme/web/settings",
            "https://vercel.com/acme/web",
        ])
        XCTAssertEqual(withAnalytics.map(\.systemImage),
                       ["key.fill", "chart.bar.xaxis", "gearshape", "square.grid.2x2"])
        XCTAssertEqual(withAnalytics.map { String(localized: $0.title) },
                       ["Environment variables", "Analytics", "Project settings", "Vercel dashboard"])
        let without = menu(Project(id: "p", name: "web", hasAnalytics: false), "acme")
        XCTAssertFalse(without.contains { $0.systemImage == "chart.bar.xaxis" })
    }

    func test_vercelPresentation() {
        let p = VercelIntegration().presentation
        XCTAssertEqual(p.vocabulary, .deployments)
        XCTAssertEqual(p.tokenCreationURL.absoluteString, "https://vercel.com/account/settings/tokens")
        XCTAssertEqual(p.ownerLabel(AccountIdentity(username: "konrad")), "konrad")
        XCTAssertNil(p.ownerLabel(nil))
    }

    // MARK: GitHub

    func test_gitHubIdentityIsTheLogin() async throws {
        let identity = try await GitHubIntegration().identity(for: githubAccount, using: credential("t", body: Data(#"{"login":"octo"}"#.utf8)))
        XCTAssertEqual(identity.username, "octo")
    }

    func test_gitHubOrganizationsComeFromRepositoryOwners() async throws {
        let body = Data(#"[{"owner":{"login":"acme","type":"Organization"}}]"#.utf8)
        let orgs = try await GitHubIntegration().organizations(for: githubAccount, using: credential("t", body: body))
        XCTAssertEqual(orgs.map(\.id), ["acme"])
    }

    func test_gitHubClientIsScopedToTheOrganization() throws {
        let scope = Scope(account: githubAccount, teamId: "acme", teamName: "acme")
        let client = try XCTUnwrap(GitHubIntegration().client(for: scope, using: .plain("t")) as? GitHubClient)
        XCTAssertEqual(client.org, "acme")
        XCTAssertNotNil(client.listing, "organization scopes share the tick's repository listing")
    }

    func test_gitHubCostMatchesTheOldBudget() {
        let cost = GitHubIntegration().pollCost
        let account = Scope(account: githubAccount, teamId: nil, teamName: nil)
        let org = Scope(account: githubAccount, teamId: "acme", teamName: nil)
        XCTAssertEqual(cost.hourlyLimit, 5000)
        XCTAssertEqual(cost.maxRequestsPerScope, 40)
        XCTAssertEqual(cost.estimatedCost(account, 3), 40, "the account scope always lists its own repositories")
        XCTAssertEqual(cost.estimatedCost(org, 0), 20, "unknown size: the fan-out cap")
        XCTAssertEqual(cost.estimatedCost(org, 3), 3)
        XCTAssertEqual(cost.estimatedCost(org, 50), 20)
        XCTAssertEqual(cost.sharedReserve([account, org]), 10)
        XCTAssertEqual(cost.sharedReserve([account]), 0)
        XCTAssertTrue(cost.metersOffCyclePolls)
        XCTAssertTrue(cost.reservesInProgressRefreshes)
    }

    func test_gitHubMenuLinksMatchTheOldMenu() {
        let links = GitHubIntegration().presentation.projectMenuLinks(
            Project(id: "acme/web", name: "acme/web", repoOrg: "acme", repoName: "web"), "acme")
        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://github.com/acme/web/pulls",
            "https://github.com/acme/web/issues",
            "https://github.com/acme/web/settings",
        ])
        XCTAssertEqual(links.map(\.systemImage), ["arrow.triangle.merge", "exclamationmark.circle", "gearshape"])
        XCTAssertEqual(links.map { String(localized: $0.title) }, ["Pull requests", "Issues", "Repository settings"])
    }

    func test_gitHubPresentation() {
        let p = GitHubIntegration().presentation
        XCTAssertEqual(p.vocabulary, .ciRuns)
        XCTAssertEqual(p.tokenCreationURL.absoluteString, "https://github.com/settings/personal-access-tokens/new")
        XCTAssertNil(p.ownerLabel(AccountIdentity(username: "octo")), "repository names already carry the owner")
    }
}
