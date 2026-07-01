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
}
