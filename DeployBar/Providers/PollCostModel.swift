import Foundation

/// What polling one provider costs, as data. `PollPlanner` sizes every tick
/// from this, so a provider's rate limit lives with the provider.
struct PollCostModel: Sendable {
    /// Hourly request ceiling the budget is sized to.
    let hourlyLimit: Int
    /// Worst-case requests of one scope's fetch; sets how often the account may poll at all.
    let maxRequestsPerScope: Int
    /// Expected requests for one scope, given how many projects it held last time (0 = unknown).
    let estimatedCost: @Sendable (_ scope: Scope, _ knownProjectCount: Int) -> Int
    /// Requests a tick spends once for all of the given scopes (GitHub's shared repository listing).
    let sharedReserve: @Sendable (_ scopes: [Scope]) -> Int
    /// Polls between timer ticks spend only the share earned since the last poll.
    let metersOffCyclePolls: Bool
    /// Each tick keeps room for the by-id re-reads of in-progress runs.
    let reservesInProgressRefreshes: Bool
}
