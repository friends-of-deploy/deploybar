import XCTest
@testable import DeployBar

final class DemoScenarioTests: XCTestCase {
    func test_decodesMinimalScenario() throws {
        let json = """
        {
          "accounts": [
            {"key": "cli", "provider": "vercel", "label": "Vercel CLI", "sourceKind": "vercelCLI",
             "teams": [{"id": "team_a", "slug": "northwind", "name": "Northwind"}]}
          ],
          "projects": [
            {"accountKey": "cli", "teamId": null, "id": "p1", "name": "storefront",
             "followed": true}
          ],
          "deployments": [
            {"accountKey": "cli", "teamId": null, "uid": "d1", "projectName": "storefront",
             "state": "READY", "ageSeconds": 120, "url": "storefront.example.app"}
          ]
        }
        """
        let scenario = try JSONDecoder().decode(DemoScenario.self, from: Data(json.utf8))

        XCTAssertEqual(scenario.accounts.count, 1)
        XCTAssertEqual(scenario.accounts[0].provider, .vercel)
        XCTAssertEqual(scenario.accounts[0].sourceKind, .vercelCLI)
        XCTAssertEqual(scenario.accounts[0].teams.first?.slug, "northwind")
        XCTAssertEqual(scenario.projects[0].name, "storefront")
        XCTAssertTrue(scenario.projects[0].followed)
        XCTAssertEqual(scenario.deployments[0].ageSeconds, 120)
        XCTAssertTrue(scenario.timeline.isEmpty, "timeline must default to empty when absent")
    }

    func test_teamsDefaultToEmptyWhenAbsent() throws {
        let json = """
        {"accounts": [{"key": "gh", "provider": "github", "label": "GitHub",
                       "sourceKind": "githubCLI"}],
         "projects": [], "deployments": []}
        """
        let scenario = try JSONDecoder().decode(DemoScenario.self, from: Data(json.utf8))
        XCTAssertTrue(scenario.accounts[0].teams.isEmpty)
    }
}
