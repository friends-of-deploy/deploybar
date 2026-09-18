import XCTest
import UserNotifications
@testable import DeployBar

@MainActor
final class NotificationActionsTests: XCTestCase {
    private let key = ProjectKey(provider: .vercel,
                                 accountId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                                 projectId: "dashboard")
    private let destination = URL(string: "https://vercel.com/acme/dashboard/build-1")!

    private var transition: StateTransition {
        StateTransition(uid: "build-1", project: "dashboard", key: key,
                        event: .failure, destinationURL: destination)
    }

    func test_notificationDeclaresMuteAction() {
        let category = NotificationManager.deploymentCategory

        XCTAssertEqual(category.identifier, NotificationActionID.deploymentCategory)
        XCTAssertEqual(category.actions.map(\.identifier), [NotificationActionID.muteProject])
    }

    func test_notificationPayloadContainsProjectAndBuildDestination() {
        let content = NotificationManager.content(for: transition)

        XCTAssertEqual(content.categoryIdentifier, NotificationActionID.deploymentCategory)
        XCTAssertEqual(content.userInfo[NotificationPayloadKey.project] as? String, key.storageString)
        XCTAssertEqual(content.userInfo[NotificationPayloadKey.destination] as? String,
                       destination.absoluteString)
    }

    func test_defaultClickRoutesToBuildDestination() {
        let command = NotificationResponseRouter.command(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: NotificationManager.content(for: transition).userInfo)

        XCTAssertEqual(command, .open(destination))
    }

    func test_muteActionRoutesToProjectKeyWithoutOpeningBuild() {
        let command = NotificationResponseRouter.command(
            actionIdentifier: NotificationActionID.muteProject,
            userInfo: NotificationManager.content(for: transition).userInfo)

        XCTAssertEqual(command, .mute(key))
    }

    func test_dismissAndMalformedPayloadDoNothing() {
        XCTAssertEqual(NotificationResponseRouter.command(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: NotificationManager.content(for: transition).userInfo), .none)
        XCTAssertEqual(NotificationResponseRouter.command(
            actionIdentifier: NotificationActionID.muteProject,
            userInfo: [:]), .none)
    }

    func test_executorMutesProjectWithoutOpeningBuild() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var opened: [URL] = []
        let executor = NotificationCommandExecutor(settings: settings) { opened.append($0) }

        executor.execute(.mute(key))

        XCTAssertTrue(settings.areNotificationsMuted(for: key))
        XCTAssertTrue(opened.isEmpty)
    }

    func test_executorOpensBuildWithoutMutingProject() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var opened: [URL] = []
        let executor = NotificationCommandExecutor(settings: settings) { opened.append($0) }

        executor.execute(.open(destination))

        XCTAssertEqual(opened, [destination])
        XCTAssertFalse(settings.areNotificationsMuted(for: key))
    }
}
