import Foundation
import UserNotifications
import os

enum NotificationGate {
    static func shouldNotify(_ t: StateTransition, settings: SettingsStore) -> Bool {
        guard settings.isProjectEnabled(t.project) else { return false }
        switch t.event {
        case .failure:  return settings.notifyOnFailure
        case .success:  return settings.notifyOnSuccess
        case .started:  return settings.notifyOnStarted
        case .canceled: return settings.notifyOnCanceled
        }
    }
}

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
        case .failure:  return "Deployment failed"
        case .success:  return "Deployment ready"
        case .started:  return "Deployment started"
        case .canceled: return "Deployment canceled"
        }
    }
}
