import XCTest
@testable import DeployBar

final class DemoProviderClientTests: XCTestCase {

    private func scenario() throws -> DemoScenario {
        let json = """
        {
          "accounts": [
            {"key": "a", "provider": "vercel", "label": "A", "sourceKind": "keychain"},
            {"key": "b", "provider": "github", "label": "B", "sourceKind": "githubCLI"}
          ],
          "projects": [
            {"accountKey": "a", "teamId": null, "id": "p1", "name": "alpha", "followed": true},
            {"accountKey": "a", "teamId": "team_x", "id": "p2", "name": "beta", "followed": true},
            {"accountKey": "b", "teamId": null, "id": "p3", "name": "gamma", "followed": false}
          ],
          "deployments": [
            {"accountKey": "a", "teamId": null, "uid": "d1", "projectName": "alpha",
             "state": "BUILDING", "ageSeconds": 60, "url": "alpha.example.app",
             "commitMessage": "Add checkout step", "commitAuthorLogin": "rmorel"},
            {"accountKey": "a", "teamId": "team_x", "uid": "d2", "projectName": "beta",
             "state": "READY", "ageSeconds": 300, "url": "beta.example.app"},
            {"accountKey": "b", "teamId": null, "uid": "d3", "projectName": "gamma",
             "state": "ERROR", "ageSeconds": 900, "url": "gamma.example.app"}
          ],
          "timeline": [
            {"atSeconds": 10, "deploymentUid": "d1", "newState": "READY"}
          ]
        }
        """
        return try JSONDecoder().decode(DemoScenario.self, from: Data(json.utf8))
    }

    func test_returnsOnlyTheRequestedScopesRows() async throws {
        let s = try scenario()
        let client = DemoProviderClient(scenario: s, accountKey: "a", teamId: nil,
                                        clock: .frozen(at: 0))

        let deps = try await client.deployments(limit: 100)
        let projs = try await client.projects()

        XCTAssertEqual(deps.map(\.uid), ["d1"], "team and other-account rows must not leak in")
        XCTAssertEqual(projs.map(\.name), ["alpha"])
    }

    func test_teamScopeIsSeparateFromPersonal() async throws {
        let s = try scenario()
        let client = DemoProviderClient(scenario: s, accountKey: "a", teamId: "team_x",
                                        clock: .frozen(at: 0))
        let deps = try await client.deployments(limit: 100)
        XCTAssertEqual(deps.map(\.uid), ["d2"])
    }

    func test_frozenClockGivesIdenticalResultsAcrossReads() async throws {
        let s = try scenario()
        let client = DemoProviderClient(scenario: s, accountKey: "a", teamId: nil,
                                        clock: .frozen(at: 0))

        let first = try await client.deployments(limit: 100)
        let second = try await client.deployments(limit: 100)

        XCTAssertEqual(first.map(\.uid), second.map(\.uid))
        XCTAssertEqual(first.map(\.stateRaw), second.map(\.stateRaw))
        XCTAssertEqual(first.map(\.createdAt), second.map(\.createdAt),
                       "a frozen clock must pin timestamps too, or screenshots drift")
    }

    func test_timelineEventAppliesOnceItsTimeHasElapsed() async throws {
        let s = try scenario()

        let before = DemoProviderClient(scenario: s, accountKey: "a", teamId: nil,
                                        clock: .frozen(at: 5))
        let after = DemoProviderClient(scenario: s, accountKey: "a", teamId: nil,
                                       clock: .frozen(at: 15))

        let d1Before = try await before.deployments(limit: 100).first
        let d1After = try await after.deployments(limit: 100).first

        XCTAssertEqual(d1Before?.state, .building)
        XCTAssertEqual(d1After?.state, .ready, "the 10s timeline event should have fired")
    }

    func test_limitIsRespected() async throws {
        let s = try scenario()
        let client = DemoProviderClient(scenario: s, accountKey: "a", teamId: nil,
                                        clock: .frozen(at: 0))
        let deployments = try await client.deployments(limit: 0)
        XCTAssertEqual(deployments.count, 0)
    }

    func test_commitMetadataSurvivesConversion() async throws {
        let s = try scenario()
        let client = DemoProviderClient(scenario: s, accountKey: "a", teamId: nil,
                                        clock: .frozen(at: 0))
        let deployments = try await client.deployments(limit: 100)
        let d = try XCTUnwrap(deployments.first)
        XCTAssertEqual(d.commitMessage, "Add checkout step")
        XCTAssertEqual(d.commitAuthorLogin, "rmorel")
    }
}
