import Foundation

/// Decides which scopes each poll tick fetches, account by account, inside
/// each provider's request budget. Every scope still refreshes; when an
/// account's scopes cost more than a tick affords, they take turns and keep
/// their last-known rows in between. The numbers come from each provider's
/// `PollCostModel`; the math from `ScopePollBudget`.
@MainActor
final class PollPlanner {
    /// Upper bound on by-id re-reads per tick. Each costs one request, so a
    /// burst of parallel CI runs can't blow through the provider's budget; any
    /// beyond the cap still refresh when their scope comes round.
    static let maxInProgressRefreshesPerTick = 10

    /// One account's situation this tick.
    struct AccountLoad {
        let account: Account
        /// Its enabled scopes, in display order.
        let scopes: [Scope]
        let cost: PollCostModel
        /// Projects a scope held on its last fetch; 0 when unknown.
        let knownProjectCount: (Scope) -> Int
        /// In-progress rows across the account's last-known results.
        let inProgressCount: Int
    }

    private var pollTimes: [UUID: Date] = [:]
    /// Where each account's rotation resumes: the first scope the last tick left out.
    private var rotationCursors: [UUID: Int] = [:]
    /// How many by-id in-progress re-reads each account's tick can still afford
    /// after its chosen scopes' fetches. Rebuilt by every `plan`; an account
    /// gated this tick has no entry, so it re-reads nothing until its next tick.
    private(set) var inProgressAllowance: [UUID: Int] = [:]

    /// The scopes to fetch now. `now` is read once per account.
    ///
    /// Only advance an account's rotation when it can actually afford a fetch:
    /// a tick then takes as many scopes, in rotation order, as its budget covers.
    func plan(_ loads: [AccountLoad], pollIntervalSeconds: Int, now: () -> Date) -> [Scope] {
        inProgressAllowance = [:]
        return loads.flatMap { load -> [Scope] in
            let accountId = load.account.id
            let scopes = load.scopes
            guard !scopes.isEmpty else { return [] }
            let interval = accountInterval(for: load, pollIntervalSeconds: pollIntervalSeconds)
            let timestamp = now()
            if interval > pollIntervalSeconds,
               let previous = pollTimes[accountId],
               timestamp.timeIntervalSince(previous) < Double(interval) { return [] }
            let offCycle = offCycleShare(for: load, interval: interval,
                                         since: pollTimes[accountId], at: timestamp)
            pollTimes[accountId] = timestamp
            let share = offCycle ?? tickShare(for: load, interval: interval)
            // The first tick starts one past the account scope.
            let start = rotationCursors[accountId, default: 1] % scopes.count
            let costs = scopes.map { cost(of: $0, in: load) }
            let budget = requestBudget(for: load, scopes: scopes, share: share)
            // A full tick always takes at least one scope; a partial share
            // takes only what it can afford, possibly none.
            let count = offCycle == nil
                ? ScopePollBudget.packedCount(costs: costs, start: start, budget: budget)
                : ScopePollBudget.fittingCount(costs: costs, start: start, budget: budget)
            rotationCursors[accountId] = (start + count) % scopes.count
            let chosen = count == scopes.count ? scopes
                                                : (0..<count).map { scopes[(start + $0) % scopes.count] }
            // What this tick actually spent is fixed now; whatever remains of
            // the share is what the in-progress re-reads may spend.
            let spent = load.cost.sharedReserve(chosen)
                + (0..<count).reduce(0) { $0 + costs[(start + $1) % scopes.count] }
            inProgressAllowance[accountId] = max(0, share - spent)
            return chosen
        }
    }

    /// How often any one of the account's scopes actually refreshes. Surfaced
    /// in Settings, so the user can see the real cadence rather than the
    /// nominal poll interval when a provider's budget stretches it out.
    func effectiveRefreshInterval(for load: AccountLoad, pollIntervalSeconds: Int) -> Int {
        let interval = accountInterval(for: load, pollIntervalSeconds: pollIntervalSeconds)
        return interval * ScopePollBudget.ticksPerRotation(
            costs: load.scopes.map { cost(of: $0, in: load) },
            budget: requestBudget(for: load, scopes: load.scopes,
                                  share: tickShare(for: load, interval: interval)))
    }

    /// Forgets accounts that are no longer connected.
    func prune(keeping liveAccountIds: Set<UUID>) {
        pollTimes = pollTimes.filter { liveAccountIds.contains($0.key) }
        rotationCursors = rotationCursors.filter { liveAccountIds.contains($0.key) }
        inProgressAllowance = inProgressAllowance.filter { liveAccountIds.contains($0.key) }
    }

    /// Equal to the poll interval until the costliest scope no longer fits one tick.
    private func accountInterval(for load: AccountLoad, pollIntervalSeconds: Int) -> Int {
        ScopePollBudget.accountIntervalSeconds(pollIntervalSeconds: pollIntervalSeconds,
                                               hourlyLimit: load.cost.hourlyLimit,
                                               requestsPerScope: load.cost.maxRequestsPerScope)
    }

    private func cost(of scope: Scope, in load: AccountLoad) -> Int {
        load.cost.estimatedCost(scope, load.knownProjectCount(scope))
    }

    private func tickShare(for load: AccountLoad, interval: Int) -> Int {
        ScopePollBudget.tickRequestBudget(pollIntervalSeconds: interval, hourlyLimit: load.cost.hourlyLimit)
    }

    /// Requests left for scope fetches: the share, less what the tick spends
    /// besides — the shared listing, and room for the in-progress re-reads.
    private func requestBudget(for load: AccountLoad, scopes: [Scope], share: Int) -> Int {
        let inProgress = load.cost.reservesInProgressRefreshes
            ? min(load.inProgressCount, Self.maxInProgressRefreshesPerTick) : 0
        return share - load.cost.sharedReserve(scopes) - inProgress
    }

    /// What a poll between timer ticks may spend: the tick share, earned back
    /// over the time since the account's last poll. Nil for a full tick.
    ///
    /// Refresh clicks, wakes and scope changes all poll off the timer. Each one
    /// spending a full share took GitHub past 5,000 requests an hour; this way
    /// a click at t+15s leaves the next tick only half a share, so the hour
    /// stays at about one share per interval however often the user refreshes.
    private func offCycleShare(for load: AccountLoad, interval: Int, since previous: Date?,
                               at timestamp: Date) -> Int? {
        guard load.cost.metersOffCyclePolls, let previous else { return nil }
        let elapsed = timestamp.timeIntervalSince(previous)
        guard elapsed < 0.9 * Double(interval) else { return nil }
        return Int(Double(tickShare(for: load, interval: interval)) * max(0, elapsed) / Double(interval))
    }
}
