import AppKit
import Foundation
import UserNotifications
import os

enum NotificationActionID {
    static let deploymentCategory = "DEPLOYMENT_EVENT"
    static let muteOptions = "MUTE_NOTIFICATION_OPTIONS"
    static let muteProject = "MUTE_PROJECT_NOTIFICATIONS"
}

enum NotificationPayloadKey {
    static let project = "projectKey"
    static let destination = "destinationURL"
    static let site = "siteURL"
    static let event = "event"
}

enum NotificationResponseCommand: Equatable {
    case open(URL)
    case mute(ProjectKey)
    case muteKind(DeploymentEvent)
    case showMuteOptions(ProjectKey, DeploymentEvent)
    case none
}

enum NotificationResponseRouter {
    static func command(actionIdentifier: String,
                        userInfo: [AnyHashable: Any],
                        clickAction: NotificationClickAction = .deployment) -> NotificationResponseCommand {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            if clickAction == .site,
               let raw = userInfo[NotificationPayloadKey.site] as? String,
               let url = URL(string: raw) {
                return .open(url)
            }
            guard let raw = userInfo[NotificationPayloadKey.destination] as? String,
                  let url = URL(string: raw) else { return .none }
            return .open(url)
        case NotificationActionID.muteOptions:
            guard let raw = userInfo[NotificationPayloadKey.project] as? String,
                  let key = ProjectKey(storageString: raw),
                  let rawEvent = userInfo[NotificationPayloadKey.event] as? String,
                  let event = DeploymentEvent(rawValue: rawEvent) else { return .none }
            return .showMuteOptions(key, event)
        case NotificationActionID.muteProject:
            guard let raw = userInfo[NotificationPayloadKey.project] as? String,
                  let key = ProjectKey(storageString: raw) else { return .none }
            return .mute(key)
        default:
            return .none
        }
    }
}

@MainActor
final class NotificationCommandExecutor: NSObject {
    private let settings: SettingsStore
    private let open: (URL) -> Void
    private let showMenu: (NSMenu) -> Void

    init(settings: SettingsStore,
         showMenu: @escaping (NSMenu) -> Void = { menu in
             // Finish the notification response before entering menu tracking.
             DispatchQueue.main.async {
                 NSApp.activate(ignoringOtherApps: true)
                 menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
             }
         },
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.settings = settings
        self.open = open
        self.showMenu = showMenu
        super.init()
    }

    func execute(_ command: NotificationResponseCommand) {
        switch command {
        case .open(let url):
            open(url)
        case .mute(let key):
            settings.setNotificationsMuted(true, for: key)
        case .muteKind(let event):
            switch event {
            case .failure: settings.notifyOnFailure = false
            case .success: settings.notifyOnSuccess = false
            case .started: settings.notifyOnStarted = false
            case .canceled: settings.notifyOnCanceled = false
            }
        case .showMuteOptions(let key, let event):
            let menu = NSMenu()
            menu.addItem(muteItem(title: String(localized: "Mute this kind"), command: .muteKind(event)))
            menu.addItem(muteItem(title: String(localized: "Mute this project"), command: .mute(key)))
            showMenu(menu)
        case .none:
            break
        }
    }

    private func muteItem(title: String, command: NotificationResponseCommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectMuteOption(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        return item
    }

    @objc private func selectMuteOption(_ item: NSMenuItem) {
        guard let command = item.representedObject as? NotificationResponseCommand else { return }
        execute(command)
    }
}

private final class NotificationResponseHandler: NSObject, UNUserNotificationCenterDelegate {
    private let executor: NotificationCommandExecutor
    private let settings: SettingsStore

    @MainActor
    init(settings: SettingsStore) {
        self.settings = settings
        self.executor = NotificationCommandExecutor(settings: settings)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            let command = NotificationResponseRouter.command(
                actionIdentifier: response.actionIdentifier,
                userInfo: response.notification.request.content.userInfo,
                clickAction: settings.notificationClickAction)
            executor.execute(command)
        }
    }
}

// Reads `SettingsStore`, which is main-actor bound; every caller
// (`DeploymentStore.handle`) is already on the main actor.
@MainActor
enum NotificationGate {
    static func shouldNotify(_ t: StateTransition, settings: SettingsStore) -> Bool {
        guard settings.isFollowed(t.key) else { return false }
        guard !settings.areNotificationsMuted(for: t.key) else { return false }
        switch t.event {
        case .failure:  return settings.notifyOnFailure
        case .success:  return settings.notifyOnSuccess
        case .started:  return settings.notifyOnStarted
        case .canceled: return settings.notifyOnCanceled
        }
    }
}

@MainActor
struct NotificationManager {
    let settings: SettingsStore
    let center: UNUserNotificationCenter
    private let responseHandler: NotificationResponseHandler

    init(settings: SettingsStore, center: UNUserNotificationCenter = .current()) {
        self.settings = settings
        self.center = center
        let responseHandler = NotificationResponseHandler(settings: settings)
        self.responseHandler = responseHandler
        center.delegate = responseHandler
    }

    static var deploymentCategory: UNNotificationCategory {
        let mute = UNNotificationAction(
            identifier: NotificationActionID.muteOptions,
            title: String(localized: "Mute...", comment: "Notification action opening mute options"),
            options: [.foreground])
        return UNNotificationCategory(identifier: NotificationActionID.deploymentCategory,
                                      actions: [mute], intentIdentifiers: [])
    }

    func requestAuthorization() {
        center.setNotificationCategories([Self.deploymentCategory])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { os_log("notification auth error: %{public}@", error.localizedDescription) }
        }
    }

    func handle(_ transitions: [StateTransition]) {
        for t in transitions where NotificationGate.shouldNotify(t, settings: settings) {
            let content = Self.content(for: t)
            center.add(UNNotificationRequest(identifier: "\(t.uid)-\(t.event.rawValue)",
                                             content: content, trigger: nil)) { error in
                if let error { os_log("notification add error: %{public}@", error.localizedDescription) }
            }
        }
    }

    static func content(for transition: StateTransition) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title(for: transition.event)
        content.body = transition.project
        content.sound = (transition.event == .failure) ? .defaultCritical : .default
        content.categoryIdentifier = NotificationActionID.deploymentCategory
        var userInfo: [String: String] = [
            NotificationPayloadKey.project: transition.key.storageString,
            NotificationPayloadKey.event: transition.event.rawValue,
        ]
        if let destination = transition.destinationURL {
            userInfo[NotificationPayloadKey.destination] = destination.absoluteString
        }
        if let site = transition.siteURL {
            userInfo[NotificationPayloadKey.site] = site.absoluteString
        }
        content.userInfo = userInfo
        return content
    }

    private static func title(for e: DeploymentEvent) -> String {
        switch e {
        case .failure:  return String(localized: "Deployment failed", comment: "Notification title")
        case .success:  return String(localized: "Deployment ready", comment: "Notification title")
        case .started:  return String(localized: "Deployment started", comment: "Notification title")
        case .canceled: return String(localized: "Deployment canceled", comment: "Notification title")
        }
    }
}
