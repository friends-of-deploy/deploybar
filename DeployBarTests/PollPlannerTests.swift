import XCTest
@testable import DeployBar

@MainActor
final class PollPlannerTests: XCTestCase {

    private let github = Account(id: UUID(), provider: .github, label: "G", source: .keychain(account: "g"))
    private let vercel = Account(id: UUID(), provider: .vercel, label: "V", source: .keychain(account: "v"))

    private func gitHubLoad(known: [String?: Int] = [:], inProgress: Int = 0) -> PollPlanner.AccountLoad {
        PollPlanner.AccountLoad(
            account: github,
            scopes: [nil, "o1", "o2"].map { Scope(account: github, teamId: $0, teamName: $0) },
            cost: GitHubIntegration().pollCost,
            knownProjectCount: { known[$0.teamId] ?? 0 },
            inProgressCount: inProgress)
    }

    /// Share 41 − listing 10 = 31: the first tick starts one past the account
    /// scope and affords one 20-request organization.
    func test_firstTickStartsPastTheAccountScope() {
        let planner = PollPlanner()
        let chosen = planner.plan([gitHubLoad()], pollIntervalSeconds: 30, now: { Date(timeIntervalSince1970: 0) })
        XCTAssertEqual(chosen.map(\.teamId), ["o1"])
        XCTAssertEqual(planner.inProgressAllowance[github.id], 41 - (10 + 20))
    }

    /// A poll 3 s after a tick earns 4 requests: too few for any scope.
    func test_offCyclePollSpendsOnlyWhatItEarned() {
        let planner = PollPlanner()
        var t = Date(timeIntervalSince1970: 0)
        _ = planner.plan([gitHubLoad()], pollIntervalSeconds: 30, now: { t })
        t.addTimeInterval(3)
        let chosen = planner.plan([gitHubLoad()], pollIntervalSeconds: 30, now: { t })
        XCTAssertTrue(chosen.isEmpty)
        XCTAssertEqual(planner.inProgressAllowance[github.id], 4)
    }

    /// 100/h at 2 requests a scope needs 72 s, so the account polls every
    /// third 30 s tick and skips the ones between.
    func test_accountSlowerThanTheTimerSkipsTicks() {
        let planner = PollPlanner()
        let cost = PollCostModel(hourlyLimit: 100, maxRequestsPerScope: 2,
                                 estimatedCost: { _, _ in 2 }, sharedReserve: { _ in 0 },
                                 metersOffCyclePolls: false, reservesInProgressRefreshes: false)
        let load = PollPlanner.AccountLoad(account: vercel, scopes: [Scope(account: vercel, teamId: nil, teamName: nil)],
                                           cost: cost, knownProjectCount: { _ in 0 }, inProgressCount: 0)
        var t = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(planner.plan([load], pollIntervalSeconds: 30, now: { t }).count, 1)
        t.addTimeInterval(30)
        XCTAssertTrue(planner.plan([load], pollIntervalSeconds: 30, now: { t }).isEmpty)
        t.addTimeInterval(60)
        XCTAssertEqual(planner.plan([load], pollIntervalSeconds: 30, now: { t }).count, 1)
    }

    func test_effectiveIntervalOfOneRepositoryOrganizations() {
        XCTAssertEqual(PollPlanner().effectiveRefreshInterval(for: gitHubLoad(known: ["o1": 1, "o2": 1]),
                                                              pollIntervalSeconds: 30), 60)
    }

    func test_pruneForgetsTheRotation() {
        let planner = PollPlanner()
        var t = Date(timeIntervalSince1970: 0)
        _ = planner.plan([gitHubLoad()], pollIntervalSeconds: 30, now: { t })
        planner.prune(keeping: [])
        t.addTimeInterval(30)
        XCTAssertEqual(planner.plan([gitHubLoad()], pollIntervalSeconds: 30, now: { t }).map(\.teamId), ["o1"],
                       "a pruned account starts its rotation again")
    }
}
