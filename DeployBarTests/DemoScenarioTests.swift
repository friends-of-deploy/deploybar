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

    func test_loaderThrowsNotFoundForAMissingScenario() {
        XCTAssertThrowsError(
            try DemoScenarioLoader.load(named: "no-such-scenario", bundle: Bundle(for: Self.self))
        ) { error in
            guard case DemoScenarioLoader.LoadError.notFound(let name) = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
            XCTAssertEqual(name, "no-such-scenario")
        }
    }

    /// The shipped fixture must always decode. A typo would otherwise surface as
    /// an empty popover in the middle of a screenshot session.
    func test_shippedDefaultFixtureDecodesAndIsWellFormed() throws {
        let appBundle = try XCTUnwrap(
            Bundle(identifier: "io.eightlines.deploybar.DeployBar"),
            "app bundle not loaded"
        )
        let scenario = try DemoScenarioLoader.load(named: "default", bundle: appBundle)

        XCTAssertEqual(scenario.accounts.count, 3)
        XCTAssertGreaterThanOrEqual(scenario.projects.count, 15)
        XCTAssertGreaterThanOrEqual(scenario.deployments.count, 20)

        // Every project and deployment must point at a declared account.
        let keys = Set(scenario.accounts.map(\.key))
        for p in scenario.projects {
            XCTAssertTrue(keys.contains(p.accountKey), "project \(p.name) has unknown account \(p.accountKey)")
        }
        for d in scenario.deployments {
            XCTAssertTrue(keys.contains(d.accountKey), "deployment \(d.uid) has unknown account \(d.accountKey)")
        }

        // Every timeline event must point at a declared deployment.
        let uids = Set(scenario.deployments.map(\.uid))
        for e in scenario.timeline {
            XCTAssertTrue(uids.contains(e.deploymentUid), "timeline references unknown deployment \(e.deploymentUid)")
        }

        // The screenshot value of the fixture is its variety of states.
        let states = Set(scenario.deployments.map(\.state))
        for expected in ["READY", "BUILDING", "QUEUED", "ERROR", "CANCELED"] {
            XCTAssertTrue(states.contains(expected), "fixture is missing a \(expected) deployment")
        }

        // Exactly one CLI account, carrying the two team scopes.
        let cli = try XCTUnwrap(scenario.accounts.first { $0.sourceKind == .vercelCLI })
        XCTAssertEqual(cli.teams.count, 2)

        XCTAssertTrue(scenario.projects.contains { $0.followed }, "no followed projects to show")
        XCTAssertTrue(scenario.projects.contains { !$0.followed }, "no unfollowed projects to show")
    }

    /// `DemoEnvironment.freezeOffsetSeconds` must sit at or past the shipped
    /// fixture's last timeline event, or `--freeze` silently regresses to
    /// capturing an intermediate state instead of the settled end-state
    /// (the exact defect this whole feature branch was fixed for). The doc
    /// comment on the constant says as much, but a comment doesn't enforce
    /// anything — this test does, against the real shipped fixture rather
    /// than a value hardcoded here.
    func test_freezeOffsetCoversTheShippedFixturesTimeline() throws {
        let appBundle = try XCTUnwrap(
            Bundle(identifier: "io.eightlines.deploybar.DeployBar"),
            "app bundle not loaded"
        )
        let scenario = try DemoScenarioLoader.load(named: "default", bundle: appBundle)

        guard let lastEventSeconds = scenario.timeline.map(\.atSeconds).max() else {
            // No timeline events means there's nothing the freeze offset could
            // possibly miss; the invariant holds vacuously.
            return
        }

        XCTAssertGreaterThanOrEqual(
            DemoEnvironment.freezeOffsetSeconds, lastEventSeconds,
            "the fixture's timeline now extends to \(lastEventSeconds)s, so " +
            "freezeOffsetSeconds must be raised past it or --freeze will " +
            "capture an intermediate state instead of the settled end-state"
        )
    }
}
