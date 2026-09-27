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

    func test_floorIsPairedWithSlowerCadenceWhenOneScopeExceedsTheTickBudget() {
        let interval = ScopePollBudget.accountIntervalSeconds(
            pollIntervalSeconds: 10, hourlyLimit: 5000, requestsPerScope: 40)
        XCTAssertEqual(interval, 30)
        let budget = ScopePollBudget.requestsPerTick(
            scopeCount: 3, pollIntervalSeconds: interval, hourlyLimit: 5000, requestsPerScope: 40)
        XCTAssertEqual(budget, 1)
        XCTAssertLessThanOrEqual(budget * (3600 / interval) * 40, 5000)
        XCTAssertEqual(ScopePollBudget.effectiveIntervalSeconds(
            scopeCount: 3, budget: budget, pollIntervalSeconds: interval), 90)
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

    func test_effectiveIntervalClampsNonPositivePollInterval() {
        // A zero or negative interval is nonsensical; clamp to 1s like
        // requestsPerTick does, rather than passing it straight through.
        XCTAssertEqual(ScopePollBudget.effectiveIntervalSeconds(
            scopeCount: 3, budget: 3, pollIntervalSeconds: 0), 1)
        XCTAssertEqual(ScopePollBudget.effectiveIntervalSeconds(
            scopeCount: 3, budget: 3, pollIntervalSeconds: -5), 1)
    }

    func test_effectiveIntervalFallsBackToClampedIntervalForNegativeBudget() {
        // A negative budget isn't a meaningful rotation; the defensive
        // fallback still clamps the interval it returns.
        XCTAssertEqual(ScopePollBudget.effectiveIntervalSeconds(
            scopeCount: 3, budget: -1, pollIntervalSeconds: 0), 1)
    }

    // MARK: tickRequestBudget

    func test_tickBudgetIsTheIntervalsShareOfTheHourlyLimit() {
        XCTAssertEqual(ScopePollBudget.tickRequestBudget(pollIntervalSeconds: 30, hourlyLimit: 5000), 41)
        XCTAssertEqual(ScopePollBudget.tickRequestBudget(pollIntervalSeconds: 3600, hourlyLimit: 5000), 5000)
    }

    func test_tickBudgetClampsNonPositiveInputs() {
        XCTAssertEqual(ScopePollBudget.tickRequestBudget(pollIntervalSeconds: 0, hourlyLimit: 3600), 1)
        XCTAssertEqual(ScopePollBudget.tickRequestBudget(pollIntervalSeconds: 30, hourlyLimit: -5), 0)
    }

    // MARK: packedCount

    func test_cheapScopesShareATick() {
        // Six 5-request organizations fit 31 requests; the 40-request account scope would not.
        XCTAssertEqual(ScopePollBudget.packedCount(costs: [40, 5, 5, 5, 5, 5, 5], start: 1, budget: 31), 6)
    }

    func test_aScopeDearerThanTheTickStillGetsItsTurn() {
        XCTAssertEqual(ScopePollBudget.packedCount(costs: [40, 5, 5], start: 0, budget: 31), 1)
    }

    func test_packingWrapsAroundTheRotation() {
        // 30 + 1 + 1 = 32 fits; the next 1 would make 33.
        XCTAssertEqual(ScopePollBudget.packedCount(costs: [1, 1, 1, 30], start: 3, budget: 32), 3)
    }

    func test_packingNeverTakesAScopeTwice() {
        XCTAssertEqual(ScopePollBudget.packedCount(costs: [1, 1, 1], start: 2, budget: 100), 3)
    }

    func test_uniformCostsRotateLikeFixedSlices() {
        // Five 2-request scopes at 4 requests a tick: two per tick.
        XCTAssertEqual(ScopePollBudget.packedCount(costs: [2, 2, 2, 2, 2], start: 4, budget: 4), 2)
    }

    func test_packingAnEmptyRotationTakesNothing() {
        XCTAssertEqual(ScopePollBudget.packedCount(costs: [], start: 0, budget: 10), 0)
    }

    // MARK: ticksPerRotation

    func test_rotationIsOneTickWhenEverythingFits() {
        XCTAssertEqual(ScopePollBudget.ticksPerRotation(costs: [2, 2, 2], budget: 166), 1)
    }

    func test_smallOrganizationsShortenTheRotation() {
        // The account scope alone, then fourteen 1-request organizations together.
        XCTAssertEqual(ScopePollBudget.ticksPerRotation(
            costs: [40] + Array(repeating: 1, count: 14), budget: 31), 2)
        // Organizations of unknown size are budgeted at the 20-request cap: one a tick.
        XCTAssertEqual(ScopePollBudget.ticksPerRotation(
            costs: [40] + Array(repeating: 20, count: 14), budget: 31), 15)
    }

    func test_emptyRotationIsOneTick() {
        XCTAssertEqual(ScopePollBudget.ticksPerRotation(costs: [], budget: 10), 1)
    }
}
