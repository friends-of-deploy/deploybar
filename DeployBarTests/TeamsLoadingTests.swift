import XCTest
@testable import DeployBar

@MainActor
final class TeamsLoadingTests: XCTestCase {
    func test_loadTeamsPopulatesTeams() async throws {
        let teamsData = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "teams", withExtension: "json")))
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            credentials: InMemoryCredentialStore(), detectCLI: { false }, detectGitHubCLI: { false })
        let vercel = accounts.addKeychainAccount(provider: .vercel, label: "Vercel", token: "t")
        let store = DeploymentStore(accountStore: accounts,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { _, _ in nil },
            organizationFetch: { req in
                (teamsData, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        await store.loadOrganizations()
        XCTAssertTrue(store.organizations(for: vercel).contains { $0.slug == "acme" })
    }
    func test_addedTokenAccountsDiscoverTheirOwnOrganizations() async {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            credentials: InMemoryCredentialStore(), detectCLI: { false }, detectGitHubCLI: { false })
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(accountStore: accounts, settings: settings,
            makeClient: { _, _ in nil }, organizationFetch: { req in
                let github = req.url!.host == "api.github.com"
                let expectedToken = github ? "github-token" : "vercel-token"
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedToken)")
                let json = github
                    ? #"[{"owner":{"login":"acme","type":"Organization"}}]"#
                    : #"{"teams":[{"id":"team_acme","slug":"acme","name":"Acme"}]}"#
                return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let github = accounts.addKeychainAccount(provider: .github, label: "GitHub", token: "github-token")
        let vercel = accounts.addKeychainAccount(provider: .vercel, label: "Vercel", token: "vercel-token")
        await store.accountsChanged()
        XCTAssertEqual(store.organizations(for: github).map(\.id), ["acme"])
        XCTAssertEqual(store.organizations(for: vercel).map(\.id), ["team_acme"])
        XCTAssertTrue(store.availableScopes.contains { $0.account.id == github.id && $0.teamId == "acme" })
        XCTAssertTrue(store.availableScopes.contains { $0.account.id == vercel.id && $0.teamId == "team_acme" })
    }

    func test_startDiscoversTokenAccountOrganizations() async {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            credentials: InMemoryCredentialStore(), detectCLI: { false }, detectGitHubCLI: { false })
        let github = accounts.addKeychainAccount(provider: .github, label: "GitHub", token: "github-token")
        let fetchedOrg = expectation(description: "startup polls discovered organization")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.pollIntervalSeconds = 60 // both scopes fit in a startup tick
        let store = DeploymentStore(accountStore: accounts,
            settings: settings,
            makeClient: { _, teamId in
                if teamId == "acme" { fetchedOrg.fulfill() }
                return nil
            }, organizationFetch: { req in
                (Data(#"[{"owner":{"login":"acme","type":"Organization"}}]"#.utf8),
                 HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, now: SteppingClock(step: 60).next)
        store.start()
        await fulfillment(of: [fetchedOrg], timeout: 2)
        XCTAssertEqual(store.organizations(for: github).map(\.id), ["acme"])
    }

}
