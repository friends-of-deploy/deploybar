import Foundation

/// How many scopes one poll tick may fetch, and which ones.
///
/// Polling every organization separately multiplies request count by the number
/// of enabled scopes. An account with 40 organizations at a 30s interval would
/// issue ~29k requests/hour against GitHub's 5000 — so when the enabled scopes
/// cost more than the limit affords, they are polled in rotation instead of all
/// at once. Every scope still refreshes; it just takes several ticks to come
/// round, and rows keep their last-known value in between.
///
/// Pure math, deliberately free of `DeploymentStore`, so the rotation can be
/// tested without standing up a store (same split as `ScopeColorIndex`).
enum ScopePollBudget {
    /// Ceiling on in-flight fetches per tick. Without it, 40 organizations open
    /// 40 simultaneous connections and GitHub sees a burst rather than a poll.
    static let maxConcurrentFetches = 6

    /// How many scopes this tick can afford.
    ///
    /// `requestsPerScope` is an estimate of what one scope costs: for GitHub
    /// that is a repo listing plus the bounded per-repo runs fan-out.
    ///
    /// The result is always floored at 1, even when a single scope's cost
    /// already exceeds `hourlyLimit` for the tick cadence implied by
    /// `pollIntervalSeconds`. In that starved case this function cannot keep
    /// usage under `hourlyLimit` — the floor wins and actual hourly usage
    /// will exceed the limit. That's deliberate: a budget of zero would stall
    /// the app entirely, which is worse than a scope polling too often. This
    /// case is not expected to be reached in practice, since `hourlyLimit` is
    /// one of a few hardcoded values (5000/2000/1000) and
    /// `pollIntervalSeconds` is floored at 10 by `SettingsStore`.
    static func requestsPerTick(scopeCount: Int,
                                pollIntervalSeconds: Int,
                                hourlyLimit: Int,
                                requestsPerScope: Int) -> Int {
        guard scopeCount > 0 else { return 0 }
        let interval = max(1, pollIntervalSeconds)
        let perScope = max(1, requestsPerScope)
        let ticksPerHour = max(1, 3600 / interval)
        let affordable = hourlyLimit / (ticksPerHour * perScope)
        // Never zero: a budget of nothing would stall the app entirely.
        return max(1, min(scopeCount, affordable))
    }

    /// The scopes to poll on `tick`, rotating so each comes round in turn.
    ///
    /// Rotation is by tick index rather than by "least recently polled" so the
    /// order is deterministic and testable, and so a scope that errors does not
    /// starve the ones behind it.
    static func slice(scopeIds: [String], budget: Int, tick: Int) -> [String] {
        guard !scopeIds.isEmpty else { return [] }
        let size = max(1, budget)
        guard size < scopeIds.count else { return scopeIds }
        let start = (tick * size) % scopeIds.count
        return (0..<size).map { scopeIds[(start + $0) % scopeIds.count] }
    }

    /// How often any one scope actually refreshes, given the rotation. Shown in
    /// Settings so the cost of enabling many organizations is visible rather
    /// than mysterious.
    static func effectiveIntervalSeconds(scopeCount: Int,
                                         budget: Int,
                                         pollIntervalSeconds: Int) -> Int {
        let interval = max(1, pollIntervalSeconds)
        // A non-positive budget isn't a meaningful rotation to compute over;
        // fall back to the plain interval as a defensive default rather than
        // dividing by a non-positive number.
        guard scopeCount > 0, budget > 0 else { return interval }
        let ticksPerRotation = Int((Double(scopeCount) / Double(budget)).rounded(.up))
        return interval * max(1, ticksPerRotation)
    }
}
