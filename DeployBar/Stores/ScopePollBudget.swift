import Foundation

/// How many scopes one poll tick may fetch, and which ones.
///
/// Polling every organization separately multiplies request count by the number
/// of enabled scopes. An account with 40 organizations at a 30s interval would
/// issue up to 192k requests/hour against GitHub's 5000 — so when the enabled scopes
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
    /// Always pair the one-scope floor with `accountIntervalSeconds`: when a
    /// tick cannot afford one scope, the account must wait several timer ticks.
    static func requestsPerTick(scopeCount: Int,
                                pollIntervalSeconds: Int,
                                hourlyLimit: Int,
                                requestsPerScope: Int) -> Int {
        guard scopeCount > 0 else { return 0 }
        let interval = max(1, pollIntervalSeconds)
        let perScope = max(1, requestsPerScope)
        let affordable = Int((Double(max(0, hourlyLimit)) * Double(interval)
                              / (3600 * Double(perScope))).rounded(.down))
        // Never zero: a budget of nothing would stall the app entirely.
        return max(1, min(scopeCount, affordable))
    }

    /// Smallest multiple of the configured timer interval that can afford a
    /// single scope. Rounding to ticks also keeps the displayed cadence honest.
    static func accountIntervalSeconds(pollIntervalSeconds: Int,
                                       hourlyLimit: Int,
                                       requestsPerScope: Int) -> Int {
        let interval = max(1, pollIntervalSeconds)
        let minimum = 3600 * Double(max(1, requestsPerScope)) / Double(max(1, hourlyLimit))
        return max(1, Int((minimum / Double(interval)).rounded(.up))) * interval
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
