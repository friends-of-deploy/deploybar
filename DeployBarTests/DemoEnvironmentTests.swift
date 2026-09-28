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

    /// A second fixture, kept separate from `scenario()` so the githubCLI
    /// coverage below doesn't disturb the account count/label assertions the
    /// other tests already make against the shared fixture.
    private func scenarioWithGitHubCLI() throws -> DemoScenario {
        let json = """
        {
          "accounts": [
            {"key": "cli", "provider": "vercel", "label": "Vercel CLI", "sourceKind": "vercelCLI"},
            {"key": "gh", "provider": "github", "label": "GitHub CLI", "sourceKind": "githubCLI"}
          ],
          "projects": [],
          "deployments": []
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

    func test_exposesScenarioTeams() async throws {
        let built = DemoEnvironment.build(scenario: try scenario(), clock: .frozen(at: 0))
        let cli = try XCTUnwrap(built.accountStore.cliAccount)
        let integration = try XCTUnwrap(built.registry.integration(for: cli.provider))
        let teams = try await integration.organizations(for: cli, using: .plain("demo-token"))
        XCTAssertEqual(teams.map(\.slug), ["northwind"])
    }

    func test_registryReturnsADemoClientForASeededAccount() async throws {
        let built = DemoEnvironment.build(scenario: try scenario(), clock: .frozen(at: 0))
        let cli = try XCTUnwrap(built.accountStore.cliAccount)
        let integration = try XCTUnwrap(built.registry.integration(for: cli.provider))
        let client = try XCTUnwrap(integration.client(for: Scope(account: cli, teamId: nil, teamName: nil),
                                                      using: .plain("demo-token")))
        let deps = try await client.deployments(limit: 100)
        XCTAssertEqual(deps.map(\.uid), ["d1"])
    }

    /// Demo screenshots have always shown only the Vercel CLI account's teams.
    func test_demoShowsOnlyTheVercelCLITeams() async throws {
        let built = DemoEnvironment.build(scenario: try DemoScenarioLoader.load(named: "default"),
                                          clock: .frozen(at: 0))
        let gh = try XCTUnwrap(built.accountStore.githubCLIAccount)
        let cli = try XCTUnwrap(built.accountStore.cliAccount)
        let github = try XCTUnwrap(built.registry.integration(for: .github))
        let vercel = try XCTUnwrap(built.registry.integration(for: .vercel))
        let ghOrgs = try await github.organizations(for: gh, using: .plain("demo-token"))
        let cliTeams = try await vercel.organizations(for: cli, using: .plain("demo-token"))
        XCTAssertTrue(ghOrgs.isEmpty)
        XCTAssertEqual(cliTeams.count, 2)
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

    func test_seedsAGitHubCLIAccount() throws {
        let built = DemoEnvironment.build(scenario: try scenarioWithGitHubCLI(), clock: .frozen(at: 0))

        let gh = try XCTUnwrap(built.accountStore.accounts.first { $0.label == "GitHub CLI" })
        XCTAssertEqual(gh.provider, .github)
        XCTAssertEqual(gh.source, .githubCLI)
        XCTAssertEqual(built.accountStore.githubCLIAccount?.id, gh.id)
    }

    /// Regression test for the freeze-offset defect: freezing the clock must
    /// actually apply timeline events that fire before the pinned offset, not
    /// just report the fixture's base state. Ties the assertion to the real
    /// `DemoEnvironment.freezeOffsetSeconds` production constant (rather than
    /// a number hardcoded here) so a future regression that reverts the
    /// offset back to 0 fails this test instead of shipping silently.
    func test_frozenClockAppliesTimelineEventsBeforeTheFreezeOffset() async throws {
        let json = """
        {
          "accounts": [
            {"key": "cli", "provider": "vercel", "label": "Vercel CLI", "sourceKind": "vercelCLI"}
          ],
          "projects": [],
          "deployments": [
            {"accountKey": "cli", "teamId": null, "uid": "d1", "projectName": "alpha",
             "state": "QUEUED", "ageSeconds": 60, "url": "alpha.example.app"}
          ],
          "timeline": [
            {"atSeconds": 10, "deploymentUid": "d1", "newState": "READY"}
          ]
        }
        """
        let scenario = try JSONDecoder().decode(DemoScenario.self, from: Data(json.utf8))

        let built = DemoEnvironment.build(
            scenario: scenario,
            clock: .frozen(at: DemoEnvironment.freezeOffsetSeconds))
        let cli = try XCTUnwrap(built.accountStore.cliAccount)
        let integration = try XCTUnwrap(built.registry.integration(for: cli.provider))
        let client = try XCTUnwrap(integration.client(for: Scope(account: cli, teamId: nil, teamName: nil),
                                                      using: .plain("demo-token")))

        let deps = try await client.deployments(limit: 100)

        XCTAssertEqual(deps.map(\.stateRaw), ["READY"],
                        "the production freeze offset must sit past the timeline event, " +
                        "so the frozen frame reflects the post-event state, not the fixture's base state")
    }

    /// End-to-end regression: the tests above build a `DemoIntegration` and
    /// call it directly with a made-up `.plain("demo-token")`, which never
    /// exercises `AccountStore.resolve`. Demo polling and team discovery
    /// actually depend on `DemoEnvironment.build` wiring `reloadCLIToken`/
    /// `reloadGitHubToken` closures (both returning "demo-token") into the
    /// CLI credential strategies, so `accountStore.resolve(account)` — which
    /// is what `DeploymentStore` really calls — resolves to a credential at
    /// all. Going through the production `DeploymentStore` init plus
    /// `loadOrganizations()`/`poll()` proves that whole path, not just the
    /// integration in isolation.
    func test_demoEndToEndThroughAccountStoreResolve() async throws {
        let built = DemoEnvironment.build(scenario: try DemoScenarioLoader.load(named: "default"),
                                          clock: .frozen(at: DemoEnvironment.freezeOffsetSeconds))
        let store = DeploymentStore(accountStore: built.accountStore, settings: built.settings,
                                    registry: built.registry)
        let cli = try XCTUnwrap(built.accountStore.cliAccount)
        let gh = try XCTUnwrap(built.accountStore.githubCLIAccount)

        await store.loadOrganizations()
        // `loadOrganizations()` already triggers a `poll()` internally when an
        // account's organizations change, but that race is an implementation
        // detail; poll explicitly (twice, so a budget-gated first tick can't
        // leave a scope unpolled) so this test doesn't depend on it.
        await store.poll()
        await store.poll()

        let cliTeams = store.organizations(for: cli)
        XCTAssertEqual(cliTeams.count, 2, "the default fixture gives the Vercel CLI account 2 teams")

        let cliTeamIds = Set(cliTeams.map(\.id))
        XCTAssertTrue(store.sourcedDeployments.contains { deployment in
            guard let teamId = deployment.teamId else { return false }
            return deployment.account.id == cli.id && cliTeamIds.contains(teamId)
        }, "at least one polled row should come from one of the CLI account's teams")

        XCTAssertTrue(store.organizations(for: gh).isEmpty,
                     "the GitHub CLI demo account has no organizations in the default fixture")
    }

    func test_reapsStaleDemoSuitesOnBuild() throws {
        let strayDomain = "io.eightlines.deploybar.demo.\(UUID().uuidString)"
        let strayDefaults = try XCTUnwrap(UserDefaults(suiteName: strayDomain))
        strayDefaults.set(true, forKey: "leftoverFromAnEarlierRun")
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: strayDomain)
        }
        XCTAssertNotNil(UserDefaults.standard.persistentDomain(forName: strayDomain),
                        "the stray domain must exist before build() runs, or this test proves nothing")

        _ = DemoEnvironment.build(scenario: try scenario(), clock: .frozen(at: 0))

        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: strayDomain),
                     "build() should reap suites left behind by earlier demo runs")
    }
}
