import Foundation
import os
import WidgetKit

protocol WidgetTimelineReloading {
    func reloadAllTimelines()
}

struct SystemWidgetReloader: WidgetTimelineReloading {
    func reloadAllTimelines() { WidgetCenter.shared.reloadAllTimelines() }
}

/// Writes the widget snapshot and asks WidgetKit to re-read it — but only when
/// it's worth a reload. WidgetKit rations reloads per day, so an unchanged
/// poll result is skipped, except for a periodic heartbeat that keeps
/// `generatedAt` fresh; without it a healthy but quiet app would look stale.
/// Reloads are also spaced at least a minute apart: a burst of changes is
/// written as it happens, and the widget picks up the latest file on the
/// first publish after the window.
@MainActor
final class WidgetPublisher {
    static let heartbeat: TimeInterval = 30 * 60
    static let minimumReloadInterval: TimeInterval = 60

    private let write: (WidgetSnapshot) throws -> Void
    private let reloader: WidgetTimelineReloading
    private let now: () -> Date
    private var lastPublished: WidgetSnapshot?
    private var lastWriteAt: Date?
    private var lastReloadAt: Date?
    private var reloadPending = false
    private let log = Logger(subsystem: "io.eightlines.deploybar", category: "widgets")

    /// Reload count for the beta's measurement, reset when the calendar day
    /// (in the current time zone) changes. `private(set)` so tests can read
    /// it without the publisher exposing a way to reset it from outside.
    private(set) var reloadsToday = 0
    private var reloadsTodayDate: Date?

    init(write: @escaping (WidgetSnapshot) throws -> Void = { try WidgetSnapshotFile.write($0) },
         reloader: WidgetTimelineReloading = SystemWidgetReloader(),
         now: @escaping () -> Date = Date.init) {
        self.write = write
        self.reloader = reloader
        self.now = now
    }

    func publish(_ snapshot: WidgetSnapshot) {
        let time = now()
        let changed = lastPublished.map { !$0.hasSameContent(as: snapshot) } ?? true
        let heartbeatDue = lastWriteAt.map { time.timeIntervalSince($0) >= Self.heartbeat } ?? true
        if changed || heartbeatDue {
            do {
                try write(snapshot)
            } catch {
                log.error("widget snapshot write failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            lastPublished = snapshot
            lastWriteAt = time
            // A heartbeat-only write just keeps `generatedAt` fresh for a quiet
            // app; nothing changed for the widget to show, so it earns no
            // reload. Only real content changes mark one pending.
            if changed { reloadPending = true }
        }
        guard reloadPending else { return }
        if let lastReloadAt, time.timeIntervalSince(lastReloadAt) < Self.minimumReloadInterval { return }
        reloader.reloadAllTimelines()
        lastReloadAt = time
        reloadPending = false
        recordReload(at: time)
    }

    private func recordReload(at time: Date) {
        let isNewDay = reloadsTodayDate.map { !Calendar.current.isDate($0, inSameDayAs: time) } ?? true
        reloadsToday = isNewDay ? 1 : reloadsToday + 1
        reloadsTodayDate = time
        log.info("widget reload #\(self.reloadsToday) today (reason: content)")
    }
}
