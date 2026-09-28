import XCTest
@testable import DeployBar

final class WidgetSelectionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func dep(_ id: String, _ state: String, minutesAgo: Double, url: String? = nil) -> WidgetDeployment {
        WidgetDeployment(id: id, stateRaw: state, target: nil, branch: "main", shortSha: nil,
                         message: nil, author: nil,
                         createdAt: t0.addingTimeInterval(-minutesAgo * 60),
                         buildingAt: nil, readyAt: nil, url: url.flatMap(URL.init(string:)))
    }

    private func project(_ key: String, _ deps: [WidgetDeployment], dashboard: String? = nil,
                         updatedAt: Date? = nil) -> WidgetProject {
        WidgetProject(key: key, name: key, provider: .vercel,
                      dashboardURL: dashboard.flatMap(URL.init(string:)), deployments: deps,
                      updatedAt: updatedAt ?? t0)
    }

    // MARK: Staleness

    func test_isStale_atThreshold() {
        XCTAssertFalse(WidgetSelection.isStale(generatedAt: t0, now: t0.addingTimeInterval(3599)))
        XCTAssertTrue(WidgetSelection.isStale(generatedAt: t0, now: t0.addingTimeInterval(3600)))
    }

    func test_timelineMarks_freshSnapshotSchedulesTheStaleFlip() {
        let now = t0.addingTimeInterval(600)
        XCTAssertEqual(WidgetSelection.timelineMarks(generatedAt: t0, now: now), [
            WidgetTimelineMark(date: now, isStale: false),
            WidgetTimelineMark(date: t0.addingTimeInterval(3600), isStale: true),
        ])
    }

    func test_timelineMarks_alreadyStaleIsASingleStaleEntry() {
        let now = t0.addingTimeInterval(7200)
        XCTAssertEqual(WidgetSelection.timelineMarks(generatedAt: t0, now: now),
                       [WidgetTimelineMark(date: now, isStale: true)])
    }

    // MARK: Featured deploy

    func test_featured_inProgressWinsOverNewerFinished() {
        let p = project("a", [dep("new", "READY", minutesAgo: 1), dep("run", "BUILDING", minutesAgo: 5)])
        XCTAssertEqual(WidgetSelection.featured(in: p)?.id, "run")
        XCTAssertEqual(WidgetSelection.lastFinished(in: p)?.id, "new")
        XCTAssertTrue(WidgetSelection.isInProgress(p))
    }

    func test_featured_newestWhenNothingRuns() {
        let p = project("a", [dep("new", "ERROR", minutesAgo: 1), dep("old", "READY", minutesAgo: 9)])
        XCTAssertEqual(WidgetSelection.featured(in: p)?.id, "new")
        XCTAssertFalse(WidgetSelection.isInProgress(p))
    }

    func test_featured_noDeploymentsIsNil() {
        XCTAssertNil(WidgetSelection.featured(in: project("a", [])))
    }

    // MARK: Links

    func test_link_prefersFeaturedDeployThenDashboard() {
        let withDeploy = project("a", [dep("d", "READY", minutesAgo: 1, url: "https://x/d")], dashboard: "https://x/a")
        XCTAssertEqual(WidgetSelection.link(for: withDeploy)?.absoluteString, "https://x/d")
        let empty = project("a", [], dashboard: "https://x/a")
        XCTAssertEqual(WidgetSelection.link(for: empty)?.absoluteString, "https://x/a")
    }

    // MARK: Project widget resolution

    func test_project_nilKeyFallsBackToMostRecentlyActive() {
        let snap = WidgetSnapshot(generatedAt: t0, projects: [
            project("old", [dep("1", "READY", minutesAgo: 60)]),
            project("new", [dep("2", "READY", minutesAgo: 1)]),
        ])
        XCTAssertEqual(WidgetSelection.project(forKey: nil, in: snap)?.key, "new")
    }

    func test_project_unknownKeyIsNil() {
        let snap = WidgetSnapshot(generatedAt: t0, projects: [project("a", [])])
        XCTAssertNil(WidgetSelection.project(forKey: "gone", in: snap),
                     "a configured project that vanished must not silently become another one")
    }

    // MARK: Projects widget selection

    func test_projects_chosenOrderKeptMissingSkippedRunningFirst() {
        let snap = WidgetSnapshot(generatedAt: t0, projects: [
            project("a", [dep("1", "READY", minutesAgo: 1)]),
            project("b", [dep("2", "READY", minutesAgo: 2)]),
            project("c", [dep("3", "BUILDING", minutesAgo: 3)]),
        ])
        let keys = WidgetSelection.projects(chosenKeys: ["b", "gone", "a", "c"], in: snap, limit: 8).map(\.key)
        XCTAssertEqual(keys, ["c", "b", "a"])
    }

    func test_projects_emptyChoiceFallsBackToRecentlyActiveWithLimit() {
        let snap = WidgetSnapshot(generatedAt: t0, projects: [
            project("idle", []),
            project("old", [dep("1", "READY", minutesAgo: 90)]),
            project("new", [dep("2", "READY", minutesAgo: 1)]),
        ])
        let keys = WidgetSelection.projects(chosenKeys: [], in: snap, limit: 2).map(\.key)
        XCTAssertEqual(keys, ["new", "old"])
    }

    // MARK: refreshDate

    func test_refreshDate_freshDataSchedulesAfterRefreshAfter() {
        XCTAssertEqual(WidgetSelection.refreshDate(asOf: t0, now: t0.addingTimeInterval(60)),
                       t0.addingTimeInterval(WidgetSelection.refreshAfter))
    }

    func test_refreshDate_alreadyStaleIsNil() {
        XCTAssertNil(WidgetSelection.refreshDate(asOf: t0, now: t0.addingTimeInterval(WidgetSelection.staleAfter)))
    }

    func test_refreshDate_nilAsOfIsNil() {
        XCTAssertNil(WidgetSelection.refreshDate(asOf: nil, now: t0))
    }

    // MARK: dataAsOf

    func test_dataAsOf_returnsOldestUpdatedAt() {
        let projects = [
            project("a", [], updatedAt: t0.addingTimeInterval(100)),
            project("b", [], updatedAt: t0),
            project("c", [], updatedAt: t0.addingTimeInterval(50)),
        ]
        XCTAssertEqual(WidgetSelection.dataAsOf(projects), t0)
    }

    func test_dataAsOf_emptyIsNil() {
        XCTAssertNil(WidgetSelection.dataAsOf([]))
    }
}
