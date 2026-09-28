import XCTest
@testable import DeployBar

@MainActor
final class WidgetPublisherTests: XCTestCase {

    final class Recorder: WidgetTimelineReloading {
        var written: [WidgetSnapshot] = []
        var reloads = 0
        func reloadAllTimelines() { reloads += 1 }
    }

    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePublisher(_ r: Recorder, failWrites: Bool = false) -> WidgetPublisher {
        WidgetPublisher(write: { snap in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            r.written.append(snap)
        }, reloader: r, now: { [unowned self] in self.clock })
    }

    /// `createdAt` is fixed regardless of `at:` — only `generatedAt` (the
    /// publisher's staleness clock) should move on an otherwise-identical poll,
    /// matching `WidgetSnapshot.hasSameContent(as:)`, which ignores `generatedAt`.
    private func snap(_ state: String, at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: date, projects: [
            WidgetProject(key: "k", name: "web", provider: .vercel, dashboardURL: nil, deployments: [
                WidgetDeployment(id: "d", stateRaw: state, target: nil, branch: nil, shortSha: nil,
                                 message: nil, author: nil,
                                 createdAt: Date(timeIntervalSince1970: 1_700_000_000), buildingAt: nil,
                                 readyAt: nil, url: nil)], updatedAt: date)
        ])
    }

    func test_firstPublishWritesAndReloads() {
        let r = Recorder()
        makePublisher(r).publish(snap("READY", at: clock))
        XCTAssertEqual(r.written.count, 1)
        XCTAssertEqual(r.reloads, 1)
    }

    func test_unchangedContentIsSkippedUntilHeartbeat() {
        let r = Recorder()
        let p = makePublisher(r)
        p.publish(snap("READY", at: clock))
        clock += 29 * 60
        p.publish(snap("READY", at: clock))
        XCTAssertEqual(r.written.count, 1, "identical content inside the heartbeat is not rewritten")
        XCTAssertEqual(r.reloads, 1)
        clock += 60
        p.publish(snap("READY", at: clock))
        XCTAssertEqual(r.reloads, 2, "heartbeat refreshes generatedAt after 30 min")
        XCTAssertEqual(r.written.last?.generatedAt, clock)
    }

    func test_changeInsideTheReloadWindowIsWrittenButItsReloadWaits() {
        let r = Recorder()
        let p = makePublisher(r)
        p.publish(snap("BUILDING", at: clock))
        clock += 10
        p.publish(snap("READY", at: clock))
        XCTAssertEqual(r.written.count, 2, "the file always holds the latest content")
        XCTAssertEqual(r.reloads, 1, "at most one reload per minute")
        clock += 51
        p.publish(snap("READY", at: clock))
        XCTAssertEqual(r.reloads, 2, "the next publish after the window flushes the pending reload")
        XCTAssertEqual(r.written.count, 2, "unchanged content is not rewritten to flush")
    }

    func test_changeAfterTheWindowReloadsImmediately() {
        let r = Recorder()
        let p = makePublisher(r)
        p.publish(snap("BUILDING", at: clock))
        clock += 60
        p.publish(snap("READY", at: clock))
        XCTAssertEqual(r.reloads, 2)
    }

    func test_failedWriteDoesNotReload() {
        let r = Recorder()
        makePublisher(r, failWrites: true).publish(snap("READY", at: clock))
        XCTAssertEqual(r.reloads, 0, "the widget would re-read the old file")
    }
}
