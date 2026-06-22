import SwiftUI

struct SettingsView: View {
    let settings: SettingsStore
    let store: DeploymentStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Account") {
                if let user = store.user {
                    LabeledContent("Account", value: user.username)
                    if let email = user.email { LabeledContent("Email", value: email) }
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
                LabeledContent("Team", value: store.scopeName)
            }
            Section("Polling") {
                Stepper("Refresh every \(intervalBinding.wrappedValue)s",
                        value: intervalBinding, in: 10...300, step: 5)
            }
            Section("Notifications") {
                Toggle("On failure", isOn: bind(\.notifyOnFailure))
                Toggle("On success", isOn: bind(\.notifyOnSuccess))
                Toggle("On started", isOn: bind(\.notifyOnStarted))
                Toggle("On canceled", isOn: bind(\.notifyOnCanceled))
            }
            Section("Notify per project") {
                if store.projects.isEmpty {
                    Text("No projects loaded yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.projects) { p in
                        Toggle(p.name, isOn: Binding(
                            get: { settings.isProjectEnabled(p.name) },
                            set: { settings.setProject(p.name, enabled: $0) }))
                    }
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LaunchAtLogin.set($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 500)
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { settings.pollIntervalSeconds },
                set: { settings.pollIntervalSeconds = $0; store.scheduleTimer() })
    }
}
