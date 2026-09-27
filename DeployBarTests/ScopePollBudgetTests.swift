import XCTest
@testable import DeployBar

/// The poll budget: how many requests a tick may spend, which scopes it packs,
/// and what that means for how often any one scope actually refreshes.
final class ScopePollBudgetTests: XCTestCase {

    func test_floorIsPairedWithSlowerCadenceWhenOneScopeExceedsTheTickBudget() {
        let interval = ScopePollBudget.accountIntervalSeconds(
            pollIntervalSeconds: 10, hourlyLimit: 5000, requestsPerScope: 40)
        XCTAssertEqual(interval, 30)
        XCTAssertGreaterThanOrEqual(
            ScopePollBudget.tickRequestBudget(pollIntervalSeconds: interval, hourlyLimit: 5000), 40,
            "the slower cadence affords the costliest scope within one tick")
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
