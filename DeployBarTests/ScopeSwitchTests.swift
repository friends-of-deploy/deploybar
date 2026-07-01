import XCTest
@testable import DeployBar

@MainActor
final class ScopeSwitchTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: n, withExtension: "json")))
    }

    // A factory that returns a client whose fetch serves the deployments fixture for any team.
    private func makeStore() throws -> DeploymentStore {
        let depData = try fixture("deployments")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let factory: (VercelCredentials) -> VercelClient = { creds in
            VercelClient(credentials: creds) { req in
                let isDep = req.url!.path.contains("deployments")
                let data = isDep ? depData : Data(#"{"projects":[]}"#.utf8)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let initial = factory(VercelCredentials(token: "tok", teamId: "team_a"))
        return DeploymentStore(client: initial, settings: settings, scopeName: "team_a", makeClient: factory)
    }

    func test_switchScopeUpdatesScopeNameAndTeamId() async throws {
        let store = try makeStore()
        await store.switchScope(teamId: "team_b", scopeName: "acme")
        XCTAssertEqual(store.scopeName, "acme")
        XCTAssertEqual(store.currentTeamId, "team_b")
    }

    func test_switchScopePersistsSelection() async throws {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let depData = try fixture("deployments")
        let settings = SettingsStore(defaults: d)
        let factory: (VercelCredentials) -> VercelClient = { creds in
            VercelClient(credentials: creds) { req in
                let isDep = req.url!.path.contains("deployments")
                return ((isDep ? depData : Data(#"{"projects":[]}"#.utf8)),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let store = DeploymentStore(client: factory(.init(token: "t", teamId: nil)), settings: settings, scopeName: "personal", makeClient: factory)
        await store.switchScope(teamId: "team_x", scopeName: "x")
        XCTAssertEqual(settings.selectedTeamId, "team_x")
    }

    func test_switchScopeRepopulatesDeployments() async throws {
        let store = try makeStore()
        await store.switchScope(teamId: "team_b", scopeName: "acme")
        XCTAssertFalse(store.deployments.isEmpty)  // re-polled the new scope
    }

    func test_switchToSameTeamIsNoop() async throws {
        let store = try makeStore()  // starts team_a
        await store.poll()
        let before = store.scopeName
        await store.switchScope(teamId: "team_a", scopeName: "ignored")
        XCTAssertEqual(store.scopeName, before)  // unchanged — same team guard
    }

    func test_selectedTeamId_personalSentinelStored() async throws {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let settings = SettingsStore(defaults: d)
        let depData = try fixture("deployments")
        let factory: (VercelCredentials) -> VercelClient = { creds in
            VercelClient(credentials: creds) { req in
                ((req.url!.path.contains("deployments") ? depData : Data(#"{"projects":[]}"#.utf8)),
                 HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let store = DeploymentStore(client: factory(.init(token: "t", teamId: "team_a")), settings: settings, scopeName: "a", makeClient: factory)
        await store.switchScope(teamId: nil, scopeName: "personal")  // switch to personal
        XCTAssertEqual(settings.selectedTeamId, "__personal__")
        XCTAssertNil(store.currentTeamId)
    }
}
