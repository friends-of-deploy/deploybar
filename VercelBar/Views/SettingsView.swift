import SwiftUI

struct SettingsView: View {
    let settings: SettingsStore
    let store: DeploymentStore

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, store: store)
                .tabItem { Label("General", systemImage: "gearshape") }

            NotificationSettingsTab(settings: settings, store: store)
                .tabItem { Label("Notifications", systemImage: "bell") }

            AccountSettingsTab(store: store)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 460)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let settings: SettingsStore
    let store: DeploymentStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Picker("Refresh status", selection: intervalBinding) {
                    Text("Every 10 seconds").tag(10)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 5 minutes").tag(300)
                }
            } footer: {
                Text("How often VercelBar checks Vercel for new deployment activity.")
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LaunchAtLogin.set($0) }))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 220)
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { settings.pollIntervalSeconds },
                set: { settings.pollIntervalSeconds = $0; store.scheduleTimer() })
    }
}

// MARK: - Notifications

private struct NotificationSettingsTab: View {
    let settings: SettingsStore
    let store: DeploymentStore

    var body: some View {
        Form {
            Section {
                Toggle("Failed deployments", isOn: bind(\.notifyOnFailure))
                Toggle("Successful deployments", isOn: bind(\.notifyOnSuccess))
                Toggle("Started deployments", isOn: bind(\.notifyOnStarted))
                Toggle("Canceled deployments", isOn: bind(\.notifyOnCanceled))
            } header: {
                Text("Notify me about")
            }

            Section {
                if store.sourcedProjects.isEmpty {
                    Text("No projects loaded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.sourcedProjects) { sp in
                        Toggle(sp.project.name, isOn: Binding(
                            get: { settings.isFollowed(sp.key) },
                            set: { settings.setFollowed(sp.key, $0) }))
                    }
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("Turn off a project to silence all of its notifications.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }
}

// MARK: - Account

private struct AccountSettingsTab: View {
    let store: DeploymentStore

    var body: some View {
        Form {
            Section {
                if let user = store.user {
                    LabeledContent("Username", value: user.username)
                    if let name = user.name { LabeledContent("Name", value: name) }
                    if let email = user.email { LabeledContent("Email", value: email) }
                } else {
                    LabeledContent("Account") {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Team", value: store.scopeName)
            } footer: {
                Text("VercelBar reuses your Vercel CLI login. Run `vercel login` in Terminal to sign in.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 220)
    }
}
