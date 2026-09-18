import XCTest
@testable import DeployBar

@MainActor
final class DemoEnvironmentTests: XCTestCase {

    private func scenario() throws -> DemoScenario {
        let json = """
        {
          "accounts": [
            {"key": "cli", "provider": "vercel", "label": "Vercel CLI", "sourceKind": "vercelCLI",
             "teams": [{"id": "team_x", "slug": "northwind", "name": "Northwind"}]},
            {"key": "side", "provider": "vercel", "label": "Side", "sourceKind": "keychain"}
          ],
          "projects": [
            {"accountKey": "cli", "teamId": null, "id": "p1", "name": "alpha", "followed": true},
            {"accountKey": "side", "teamId": null, "id": "p2", "name": "beta", "followed": false}
          ],
          "deployments": [
            {"accountKey": "cli", "teamId": null, "uid": "d1", "projectName": "alpha",
             "state": "READY", "ageSeconds": 60, "url": "alpha.example.app"}
          ]
        }
        """
        return try JSONDecoder().decode(DemoScenario.self, from: Data(json.utf8))
    }

    func test_seedsOneAccountPerScenarioAccount() throws {
        let built = DemoEnvironment.build(scenario: try scenario(), clock: .frozen(at: 0))

        XCTAssertEqual(built.accountStore.accounts.count, 2)
        XCTAssertEqual(built.accountStore.accounts.map(\.label), ["Vercel CLI", "Side"])
        XCTAssertNotNil(built.accountStore.cliAccount, "the vercelCLI account drives team scopes")
    }

    func test_exposesScenarioTeams() throws {
        let built = DemoEnvironment.build(scenario: try scenario(), clock: .frozen(at: 0))
        XCTAssertEqual(built.teams.map(\.slug), ["northwind"])
    }

    func test_factoryReturnsADemoClientForASeededAccount() async throws {
        let built = DemoEnvironment.build(scenario: try scenario(), clock: .frozen(at: 0))
        let cli = try XCTUnwrap(built.accountStore.cliAccount)

        let client = try XCTUnwrap(built.makeClient(cli, nil))
        let deps = try await client.deployments(limit: 100)

        XCTAssertEqual(deps.map(\.uid), ["d1"])
    }

    func test_appliesFollowStateFromTheScenario() throws {
        let built = DemoEnvironment.build(scenario: try scenario(), clock: .frozen(at: 0))
        let cli = try XCTUnwrap(built.accountStore.cliAccount)
        let side = try XCTUnwrap(built.accountStore.accounts.first { $0.label == "Side" })

        XCTAssertTrue(built.settings.isFollowed(
            ProjectKey(provider: .vercel, accountId: cli.id, projectId: "p1")))
        XCTAssertFalse(built.settings.isFollowed(
            ProjectKey(provider: .vercel, accountId: side.id, projectId: "p2")))
    }

    func test_doesNotTouchTheStandardDefaultsDomain() throws {
        let sentinel = "connectedAccounts"
        let before = UserDefaults.standard.data(forKey: sentinel)

        _ = DemoEnvironment.build(scenario: try scenario(), clock: .frozen(at: 0))

        XCTAssertEqual(UserDefaults.standard.data(forKey: sentinel), before,
                       "demo mode must never write to the real defaults domain")
    }

    func test_buildFromEnvironmentIsNilWhenTheFlagIsAbsent() {
        XCTAssertNil(DemoEnvironment.buildFromEnvironment(environment: [:]))
        XCTAssertNil(DemoEnvironment.buildFromEnvironment(environment: ["DEPLOYBAR_DEMO": "0"]))
    }

    func test_isEnabledReadsTheFlag() {
        XCTAssertTrue(DemoEnvironment.isEnabled(in: ["DEPLOYBAR_DEMO": "1"]))
        XCTAssertFalse(DemoEnvironment.isEnabled(in: ["DEPLOYBAR_DEMO": "yes"]))
        XCTAssertFalse(DemoEnvironment.isEnabled(in: [:]))
    }
}
