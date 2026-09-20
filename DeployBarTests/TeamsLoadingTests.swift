import XCTest
@testable import DeployBar

@MainActor
final class TeamsLoadingTests: XCTestCase {
    func test_loadTeamsPopulatesTeams() async throws {
        let teamsData = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "teams", withExtension: "json")))
        let depData = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "deployments", withExtension: "json")))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let factory: (VercelCredentials) -> VercelClient = { creds in
            VercelClient(credentials: creds) { req in
                ((req.url!.path.contains("deployments") ? depData : Data(#"{"projects":[]}"#.utf8)),
                 HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let teamsClient = TeamsClient(token: "t") { req in
            (teamsData, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let store = DeploymentStore(client: factory(.init(token: "t", teamId: nil)),
                                    settings: settings, scopeName: "personal",
                                    makeClient: factory, teamsClient: teamsClient)
        await store.loadTeams()
        XCTAssertFalse(store.teams.isEmpty)
        XCTAssertTrue(store.teams.contains { $0.slug == "acme" })
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
            })
        store.start()
        await fulfillment(of: [fetchedOrg], timeout: 2)
        XCTAssertEqual(store.organizations(for: github).map(\.id), ["acme"])
    }

}
