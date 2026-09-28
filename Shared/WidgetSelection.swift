import Foundation

/// One entry in a widget timeline: when it takes effect and whether the data
/// should read as stale by then.
struct WidgetTimelineMark: Equatable {
    let date: Date
    let isStale: Bool
}

/// Pure decisions both widgets make. Kept out of the extension so the app's
/// test target can cover them.
enum WidgetSelection {
    /// Data this old reads as "DeployBar stopped updating". The app refreshes
    /// the snapshot at least every 30 minutes while running (heartbeat), so a
    /// live app never trips this.
    static let staleAfter: TimeInterval = 60 * 60

    static func isStale(generatedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(generatedAt) >= staleAfter
    }

    /// A widget's staleness clock covers several projects at once (the Projects
    /// widget's grid), so it uses the oldest of their `updatedAt` — the one
    /// most likely to be showing replayed data.
    static func dataAsOf(_ projects: [WidgetProject]) -> Date? {
        projects.map(\.updatedAt).min()
    }

    /// A fresh entry now plus a pre-scheduled stale one, so a widget whose app
    /// has quit turns stale on its own without spending a reload.
    static func timelineMarks(generatedAt: Date, now: Date) -> [WidgetTimelineMark] {
        if isStale(generatedAt: generatedAt, now: now) {
            return [WidgetTimelineMark(date: now, isStale: true)]
        }
        return [WidgetTimelineMark(date: now, isStale: false),
                WidgetTimelineMark(date: generatedAt.addingTimeInterval(staleAfter), isStale: true)]
    }

    /// The deploy a project is represented by: a running one wins over any
    /// newer finished one, matching the popover's "live status first" rule.
    static func featured(in project: WidgetProject) -> WidgetDeployment? {
        project.deployments.first { $0.state.isInProgress } ?? project.deployments.first
    }

    /// Newest deploy that has finished — shown under a running one.
    static func lastFinished(in project: WidgetProject) -> WidgetDeployment? {
        project.deployments.first { !$0.state.isInProgress }
    }

    static func isInProgress(_ project: WidgetProject) -> Bool {
        featured(in: project)?.state.isInProgress == true
    }

    /// Where a click on the project as a whole goes.
    static func link(for project: WidgetProject) -> URL? {
        featured(in: project)?.url ?? project.dashboardURL
    }

    /// Newest activity first; projects with no deploys last, by name.
    static func recentlyActive(_ projects: [WidgetProject]) -> [WidgetProject] {
        projects.sorted { a, b in
            let da = a.deployments.first?.createdAt ?? .distantPast
            let db = b.deployments.first?.createdAt ?? .distantPast
            if da != db { return da > db }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The Project widget's project. No key (not configured yet) → the most
    /// recently active one; a key that's no longer in the snapshot → nil, so the
    /// widget can say so instead of quietly showing a different project.
    static func project(forKey key: String?, in snapshot: WidgetSnapshot) -> WidgetProject? {
        guard let key else { return recentlyActive(snapshot.projects).first }
        return snapshot.projects.first { $0.key == key }
    }

    /// The Projects widget's rows: the chosen projects in the chosen order
    /// (vanished ones skipped), or the most recently active when none are
    /// chosen; running projects float to the top either way.
    static func projects(chosenKeys: [String], in snapshot: WidgetSnapshot, limit: Int) -> [WidgetProject] {
        let base: [WidgetProject]
        if chosenKeys.isEmpty {
            base = recentlyActive(snapshot.projects)
        } else {
            let byKey = Dictionary(snapshot.projects.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            base = chosenKeys.compactMap { byKey[$0] }
        }
        let running = base.filter(isInProgress)
        let rest = base.filter { !isInProgress($0) }
        return Array((running + rest).prefix(limit))
    }
}
