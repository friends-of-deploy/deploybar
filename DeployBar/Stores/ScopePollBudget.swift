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
/// A tick has a request budget and packs scopes by what each costs, so
/// organizations with a handful of repositories share a tick rather than each
/// taking one sized for the worst case.
///
/// Pure math, deliberately free of `DeploymentStore`, so the rotation can be
/// tested without standing up a store (same split as `ScopeColorIndex`).
enum ScopePollBudget {
    /// Ceiling on in-flight fetches per tick. Without it, 40 organizations open
    /// 40 simultaneous connections and GitHub sees a burst rather than a poll.
    static let maxConcurrentFetches = 6

    /// Smallest multiple of the configured timer interval that can afford a
    /// single scope. Rounding to ticks also keeps the displayed cadence honest.
    static func accountIntervalSeconds(pollIntervalSeconds: Int,
                                       hourlyLimit: Int,
                                       requestsPerScope: Int) -> Int {
        let interval = max(1, pollIntervalSeconds)
        let minimum = 3600 * Double(max(1, requestsPerScope)) / Double(max(1, hourlyLimit))
        return max(1, Int((minimum / Double(interval)).rounded(.up))) * interval
    }

    /// Requests one tick of an account may spend: its share of the hourly limit.
    static func tickRequestBudget(pollIntervalSeconds: Int, hourlyLimit: Int) -> Int {
        Int((Double(max(0, hourlyLimit)) * Double(max(1, pollIntervalSeconds)) / 3600).rounded(.down))
    }

    /// How many scopes, taken in rotation order from `start`, fit in `budget`
    /// requests. Always at least one, so a scope dearer than a whole tick still
    /// gets its turn — `accountIntervalSeconds` keeps that one inside the limit.
    static func packedCount(costs: [Int], start: Int, budget: Int) -> Int {
        guard !costs.isEmpty else { return 0 }
        var spent = 0
        var taken = 0
        while taken < costs.count {
            let cost = max(0, costs[(start + taken) % costs.count])
            if taken > 0, spent + cost > budget { break }
            spent += cost
            taken += 1
        }
        return taken
    }

    /// How many scopes, taken in rotation order from `start`, fit in `budget`
    /// requests — with no floor, so possibly none. For a poll between timer
    /// ticks: it has only part of a tick's share, and a scope it can't afford
    /// waits for the next tick rather than overspending the hour.
    static func fittingCount(costs: [Int], start: Int, budget: Int) -> Int {
        var spent = 0
        var taken = 0
        while taken < costs.count {
            let cost = max(0, costs[(start + taken) % costs.count])
            if spent + cost > budget { break }
            spent += cost
            taken += 1
        }
        return taken
    }

    /// Ticks one full rotation takes when every tick packs as many scopes as
    /// fit. Shown in Settings, so the cost of enabling many organizations is
    /// visible rather than mysterious.
    static func ticksPerRotation(costs: [Int], budget: Int) -> Int {
        guard !costs.isEmpty else { return 1 }
        var covered = 0
        var ticks = 0
        while covered < costs.count {
            covered += packedCount(costs: costs, start: covered, budget: budget)
            ticks += 1
        }
        return ticks
    }
}
