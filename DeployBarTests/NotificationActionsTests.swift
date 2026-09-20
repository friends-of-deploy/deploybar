import XCTest
import AppKit
import UserNotifications
@testable import DeployBar

@MainActor
final class NotificationActionsTests: XCTestCase {
    private let key = ProjectKey(provider: .vercel,
                                 accountId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                                 projectId: "dashboard")
    private let destination = URL(string: "https://vercel.com/acme/dashboard/build-1")!
    private let site = URL(string: "https://dashboard.vercel.app")!

    private var transition: StateTransition {
        StateTransition(uid: "build-1", project: "dashboard", key: key,
                        event: .failure, destinationURL: destination, siteURL: site)
    }

    func test_notificationDeclaresMuteAction() {
        let category = NotificationManager.deploymentCategory

        XCTAssertEqual(category.identifier, NotificationActionID.deploymentCategory)
        XCTAssertEqual(category.actions.map(\.identifier), [NotificationActionID.muteOptions])
        XCTAssertEqual(category.actions.first?.title, String(localized: "Mute..."))
    }

    func test_notificationPayloadContainsProjectAndBuildDestination() {
        let content = NotificationManager.content(for: transition)

        XCTAssertEqual(content.categoryIdentifier, NotificationActionID.deploymentCategory)
        XCTAssertEqual(content.userInfo[NotificationPayloadKey.project] as? String, key.storageString)
        XCTAssertEqual(content.userInfo[NotificationPayloadKey.destination] as? String,
                       destination.absoluteString)
        XCTAssertEqual(content.userInfo[NotificationPayloadKey.site] as? String, site.absoluteString)
        XCTAssertEqual(content.userInfo[NotificationPayloadKey.event] as? String, "failure")
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

    func test_sitePreferenceOpensSite() {
        XCTAssertEqual(NotificationResponseRouter.command(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: NotificationManager.content(for: transition).userInfo,
            clickAction: .site), .open(site))
    }

    func test_sitePreferenceFallsBackToDeploymentForOldOrSitelessNotifications() {
        let payload: [AnyHashable: Any] = [NotificationPayloadKey.destination: destination.absoluteString]
        XCTAssertEqual(NotificationResponseRouter.command(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: payload, clickAction: .site), .open(destination))
    }

    func test_muteOptionsRoutesToProjectAndEvent() {
        XCTAssertEqual(NotificationResponseRouter.command(
            actionIdentifier: NotificationActionID.muteOptions,
            userInfo: NotificationManager.content(for: transition).userInfo),
                       .showMuteOptions(key, .failure))
        XCTAssertEqual(NotificationResponseRouter.command(
            actionIdentifier: NotificationActionID.muteOptions,
            userInfo: [NotificationPayloadKey.project: key.storageString,
                       NotificationPayloadKey.event: "unknown"]), .none)
    }

    func test_muteMenuWaitsForSelectionAndExecutesKindChoice() throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var menu: NSMenu?
        var opened: [URL] = []
        let executor = NotificationCommandExecutor(settings: settings, showMenu: { menu = $0 },
                                                   open: { opened.append($0) })
        executor.execute(.showMuteOptions(key, .failure))

        let choices = try XCTUnwrap(menu)
        XCTAssertEqual(choices.items.map(\.title), [String(localized: "Mute this kind"),
                                                  String(localized: "Mute this project")])
        XCTAssertTrue(settings.notifyOnFailure)
        XCTAssertFalse(settings.areNotificationsMuted(for: key))
        XCTAssertTrue(opened.isEmpty)

        choices.performActionForItem(at: 0)
        XCTAssertFalse(settings.notifyOnFailure)
        XCTAssertFalse(settings.areNotificationsMuted(for: key))
        XCTAssertTrue(opened.isEmpty)
    }

    func test_muteMenuProjectChoiceKeepsEventEnabled() throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var menu: NSMenu?
        let executor = NotificationCommandExecutor(settings: settings, showMenu: { menu = $0 })
        executor.execute(.showMuteOptions(key, .failure))

        try XCTUnwrap(menu).performActionForItem(at: 1)

        XCTAssertTrue(settings.areNotificationsMuted(for: key))
        XCTAssertTrue(settings.isFollowed(key))
        XCTAssertTrue(settings.notifyOnFailure)
    }

    func test_mutingEachKindOnlySuppressesThatEventAcrossProjectsAndPersists() {
        let events: [DeploymentEvent] = [.failure, .success, .started, .canceled]
        let otherKey = ProjectKey(provider: .github, accountId: UUID(), projectId: "acme/app")
        for mutedEvent in events {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let settings = SettingsStore(defaults: defaults)
            settings.notifyOnStarted = true
            settings.notifyOnCanceled = true
            NotificationCommandExecutor(settings: settings).execute(.muteKind(mutedEvent))

            let reloaded = SettingsStore(defaults: defaults)
            for projectKey in [key, otherKey] {
                for event in events {
                    let transition = StateTransition(uid: "build", project: "app", key: projectKey, event: event)
                    XCTAssertEqual(NotificationGate.shouldNotify(transition, settings: reloaded), event != mutedEvent)
                }
                XCTAssertFalse(reloaded.areNotificationsMuted(for: projectKey))
            }
        }
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
