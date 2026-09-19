import XCTest
@testable import DeployBar

/// The poll budget: how many scopes a tick may fetch, which ones it picks, and
/// what that means for how often any one scope actually refreshes.
final class ScopePollBudgetTests: XCTestCase {

    // MARK: requestsPerTick

    func test_everyScopeFitsWhenTheLimitIsGenerous() {
        // 3 scopes, 30s interval → 120 ticks/hour. 3 * 120 * 6 = 2160 < 5000.
        let budget = ScopePollBudget.requestsPerTick(
            scopeCount: 3, pollIntervalSeconds: 30, hourlyLimit: 5000, requestsPerScope: 6)
        XCTAssertEqual(budget, 3)
    }

    func test_budgetIsCappedWhenScopesWouldExhaustTheLimit() {
        // 40 scopes * 120 ticks * 6 requests = 28800, far over 5000.
        // Affordable per tick: 5000 / (120 * 6) = 6.
        let budget = ScopePollBudget.requestsPerTick(
            scopeCount: 40, pollIntervalSeconds: 30, hourlyLimit: 5000, requestsPerScope: 6)
        XCTAssertEqual(budget, 6)
    }

    func test_budgetIsNeverZero() {
        // Even a hostile configuration must poll something, or the app is dead.
        let budget = ScopePollBudget.requestsPerTick(
            scopeCount: 500, pollIntervalSeconds: 10, hourlyLimit: 60, requestsPerScope: 50)
        XCTAssertEqual(budget, 1)
    }

    // MARK: slice

    func test_sliceReturnsEveryScopeWhenBudgetCoversThem() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(ScopePollBudget.slice(scopeIds: ids, budget: 3, tick: 0), ids)
        XCTAssertEqual(ScopePollBudget.slice(scopeIds: ids, budget: 5, tick: 7), ids)
    }

    func test_sliceRotatesAcrossTicks() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(ScopePollBudget.slice(scopeIds: ids, budget: 2, tick: 0), ["a", "b"])
        XCTAssertEqual(ScopePollBudget.slice(scopeIds: ids, budget: 2, tick: 1), ["c", "d"])
        // Wraps around and picks up where it left off.
        XCTAssertEqual(ScopePollBudget.slice(scopeIds: ids, budget: 2, tick: 2), ["e", "a"])
    }

    func test_everyScopeIsPolledWithinOneFullRotation() {
        let ids = (0..<17).map { "scope-\($0)" }
        var seen = Set<String>()
        // ceil(17 / 4) = 5 ticks to cover them all.
        for tick in 0..<5 {
            seen.formUnion(ScopePollBudget.slice(scopeIds: ids, budget: 4, tick: tick))
        }
        XCTAssertEqual(seen.count, ids.count)
    }

    func test_sliceHandlesAnEmptyScopeList() {
        XCTAssertTrue(ScopePollBudget.slice(scopeIds: [], budget: 4, tick: 3).isEmpty)
    }

    // MARK: effectiveInterval

    func test_effectiveIntervalMatchesPollIntervalWhenNothingIsDeferred() {
        XCTAssertEqual(ScopePollBudget.effectiveIntervalSeconds(
            scopeCount: 3, budget: 3, pollIntervalSeconds: 30), 30)
    }

    func test_effectiveIntervalStretchesWhenScopesRotate() {
        // 40 scopes, 6 per tick → 7 ticks per rotation → 210s.
        XCTAssertEqual(ScopePollBudget.effectiveIntervalSeconds(
            scopeCount: 40, budget: 6, pollIntervalSeconds: 30), 210)
    }
}
