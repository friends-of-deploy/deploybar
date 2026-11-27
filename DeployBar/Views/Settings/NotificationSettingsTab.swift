import SwiftUI

/// Which deployment outcomes are worth a banner.
struct NotificationSettingsTab: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section { NotificationPermissionRow() }
            Section {
                Toggle(String(localized: "Pipeline failed", comment: "Notification title and its settings toggle"),
                       isOn: bind(\.notifyOnFailure))
                Toggle(String(localized: "Pipeline done", comment: "Notification title and its settings toggle"),
                       isOn: bind(\.notifyOnSuccess))
                Toggle(String(localized: "Pipeline started", comment: "Notification title and its settings toggle"),
                       isOn: bind(\.notifyOnStarted))
                Toggle(String(localized: "Pipeline canceled", comment: "Notification title and its settings toggle"),
                       isOn: bind(\.notifyOnCanceled))
            } header: {
                Text("Notify me when")
            } footer: {
                Text(String(localized: "Notifications only arrive for projects you follow.",
                            comment: "Notifications tab footer"))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("On notification click", selection: Binding(
                    get: { settings.notificationClickAction },
                    set: { settings.notificationClickAction = $0 })) {
                    Text("Open deployment").tag(NotificationClickAction.deployment)
                    Text("Open site (if available)").tag(NotificationClickAction.site)
                }
            } footer: {
                Text("If the site URL is unavailable, opens the deployment instead.")
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }
}
