import Foundation

/// "Now", for demo mode.
///
/// Live mode reports real elapsed time since launch, so builds progress and the
/// UI can be filmed in motion. Frozen mode always reports the same offset, so
/// two runs a release apart produce identical pixels. Every time-dependent
/// demo read goes through here, which is what makes the freeze switch a single
/// behavioural change instead of a flag threaded through the fixture code.
final class DemoClock: @unchecked Sendable {
    private let start: Date
    private let frozenAt: Double?
    private let nowProvider: () -> Date

    init(frozenAt: Double?, now: @escaping () -> Date = Date.init) {
        self.frozenAt = frozenAt
        self.nowProvider = now
        self.start = now()
    }

    /// Seconds since the demo started, or the pinned offset when frozen.
    var elapsed: Double {
        if let frozenAt { return frozenAt }
        return nowProvider().timeIntervalSince(start)
    }

    var now: Date { start.addingTimeInterval(elapsed) }

    static func live() -> DemoClock { DemoClock(frozenAt: nil) }
    static func frozen(at seconds: Double = 0) -> DemoClock { DemoClock(frozenAt: seconds) }
}
