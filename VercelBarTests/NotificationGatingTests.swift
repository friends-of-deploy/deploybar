import XCTest
@testable import VercelBar

final class NotificationGatingTests: XCTestCase {
    private func settings(failure: Bool = true, success: Bool = true,
                          started: Bool = false, canceled: Bool = false) -> SettingsStore {
        let s = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        s.notifyOnFailure = failure; s.notifyOnSuccess = success
        s.notifyOnStarted = started; s.notifyOnCanceled = canceled
        return s
    }
    private func t(_ event: DeploymentEvent, project: String = "p") -> StateTransition {
        StateTransition(uid: "1", project: project, event: event)
    }

    func test_failureFiresByDefault() {
        XCTAssertTrue(NotificationGate.shouldNotify(t(.failure), settings: settings()))
    }
    func test_successFiresByDefault() {
        XCTAssertTrue(NotificationGate.shouldNotify(t(.success), settings: settings()))
    }
    func test_startedSuppressedByDefault() {
        XCTAssertFalse(NotificationGate.shouldNotify(t(.started), settings: settings()))
    }
    func test_canceledSuppressedByDefault() {
        XCTAssertFalse(NotificationGate.shouldNotify(t(.canceled), settings: settings()))
    }
    func test_startedFiresWhenEnabled() {
        XCTAssertTrue(NotificationGate.shouldNotify(t(.started), settings: settings(started: true)))
    }
    func test_canceledFiresWhenEnabled() {
        XCTAssertTrue(NotificationGate.shouldNotify(t(.canceled), settings: settings(canceled: true)))
    }
    func test_failureSuppressedWhenDisabled() {
        XCTAssertFalse(NotificationGate.shouldNotify(t(.failure), settings: settings(failure: false)))
    }
    func test_perProjectOptOutBlocksEvenEnabledEvent() {
        let s = settings()
        s.setProject("p", enabled: false)
        XCTAssertFalse(NotificationGate.shouldNotify(t(.failure, project: "p"), settings: s))
    }
    func test_perProjectOptOutDoesNotAffectOtherProjects() {
        let s = settings()
        s.setProject("other", enabled: false)
        XCTAssertTrue(NotificationGate.shouldNotify(t(.failure, project: "p"), settings: s))
    }
}
