import Foundation
import UserNotifications
import os

// Reads `SettingsStore`, which is main-actor bound; every caller
// (`DeploymentStore.handle`) is already on the main actor.
@MainActor
enum NotificationGate {
    static func shouldNotify(_ t: StateTransition, settings: SettingsStore) -> Bool {
        guard settings.isFollowed(t.key) else { return false }
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
    var center: UNUserNotificationCenter = .current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { os_log("notification auth error: %{public}@", error.localizedDescription) }
        }
    }

    func handle(_ transitions: [StateTransition]) {
        for t in transitions where NotificationGate.shouldNotify(t, settings: settings) {
            let content = UNMutableNotificationContent()
            content.title = title(for: t.event)
            content.body = t.project
            content.sound = (t.event == .failure) ? .defaultCritical : .default
            center.add(UNNotificationRequest(identifier: "\(t.uid)-\(t.event.rawValue)",
                                             content: content, trigger: nil)) { error in
                if let error { os_log("notification add error: %{public}@", error.localizedDescription) }
            }
        }
    }

    private func title(for e: DeploymentEvent) -> String {
        switch e {
        case .failure:  return String(localized: "Deployment failed", comment: "Notification title")
        case .success:  return String(localized: "Deployment ready", comment: "Notification title")
        case .started:  return String(localized: "Deployment started", comment: "Notification title")
        case .canceled: return String(localized: "Deployment canceled", comment: "Notification title")
        }
    }
}
