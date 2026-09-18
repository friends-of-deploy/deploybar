import Foundation

/// A `DeploymentProviderClient` backed by a fixture instead of the network.
///
/// One instance serves one scope (account + optional team), mirroring how the
/// real clients are built per scope by `ClientFactory`. Timeline progression is
/// a pure function of `clock.elapsed` evaluated on each call, so the store's
/// existing poll timer drives the simulation and a frozen clock is deterministic
/// by construction — no timer, no mutable state, nothing to race.
struct DemoProviderClient: DeploymentProviderClient {
    let scenario: DemoScenario
    let accountKey: String
    let teamId: String?
    let clock: DemoClock

    init(scenario: DemoScenario, accountKey: String, teamId: String?, clock: DemoClock) {
        self.scenario = scenario
        self.accountKey = accountKey
        self.teamId = teamId
        self.clock = clock
    }

    func deployments(limit: Int) async throws -> [Deployment] {
        let elapsed = clock.elapsed
        let now = clock.now.timeIntervalSince1970

        // Latest state wins: events are applied in time order up to `elapsed`.
        var stateOverrides: [String: String] = [:]
        for event in scenario.timeline.sorted(by: { $0.atSeconds < $1.atSeconds })
        where event.atSeconds <= elapsed {
            stateOverrides[event.deploymentUid] = event.newState
        }

        return scenario.deployments
            .filter { $0.accountKey == accountKey && $0.teamId == teamId }
            .prefix(max(0, limit))
            .map { fixture in
                let state = stateOverrides[fixture.uid] ?? fixture.state
                let createdAt = (now - fixture.ageSeconds) * 1000   // ms, as the API reports
                return Deployment(
                    uid: fixture.uid,
                    name: fixture.projectName,
                    stateRaw: state,
                    url: fixture.url,
                    createdAt: createdAt,
                    creatorUsername: fixture.creatorUsername,
                    commitOrg: fixture.commitOrg,
                    commitRepo: fixture.commitRepo,
                    commitSha: fixture.commitSha,
                    commitRef: fixture.commitRef,
                    commitMessage: fixture.commitMessage,
                    commitAuthorLogin: fixture.commitAuthorLogin
                )
            }
    }

    func projects() async throws -> [Project] {
        scenario.projects
            .filter { $0.accountKey == accountKey && $0.teamId == teamId }
            .map { fixture in
                Project(
                    id: fixture.id,
                    name: fixture.name,
                    repoType: fixture.repoOrg == nil ? nil : "github",
                    repoOrg: fixture.repoOrg,
                    repoName: fixture.repoName,
                    productionURL: fixture.productionURL,
                    framework: fixture.framework,
                    latestStateRaw: fixture.latestState,
                    starCount: fixture.starCount,
                    openIssueCount: fixture.openIssueCount
                )
            }
    }
}
