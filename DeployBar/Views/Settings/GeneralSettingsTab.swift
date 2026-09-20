import SwiftUI

/// Polling cadence, startup behaviour and the app's own identity — the
/// settings a user is most likely to open the window for.
struct GeneralSettingsTab: View {
    let settings: SettingsStore
    let store: DeploymentStore
    var openOnboarding: () -> Void = {}
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Refresh status", comment: "Poll interval picker label"),
                       selection: intervalBinding) {
                    Text("Every 10 seconds").tag(10)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 5 minutes").tag(300)
                }
            } footer: {
                Text("How often DeployBar checks for new deployment activity.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "Launch at login", comment: "Launch at login toggle"),
                       isOn: Binding(
                        get: { launchAtLogin },
                        // Not a stored preference: the setter hands the change
                        // to the system, then the toggle shows what it took.
                        set: { launchAtLogin = $0; LaunchAtLogin.set($0) }))
            }

            Section {
                Button("Show welcome guide", action: openOnboarding)
            }

            Section {
                CrashReportingPreference(settings: settings)
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent(String(localized: "Website", comment: "About row label")) {
                    Link(AppInfo.websiteLabel, destination: AppInfo.websiteURL)
                }
                // "GitHub" is a proper noun, same in every language.
                LabeledContent("GitHub") {
                    Link(AppInfo.githubLabel, destination: AppInfo.githubURL)
                }
                LabeledContent(String(localized: "Contact", comment: "About row label")) {
                    Button(String(localized: "Send email", comment: "About contact button")) {
                        NSWorkspace.shared.open(AppInfo.contactURL)
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text(String(localized: "About", comment: "About section header"))
            }
        }
        .formStyle(.grouped)
        .task {
            // The user may have removed the app from Login Items while this
            // window was closed.
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { settings.pollIntervalSeconds },
                set: { settings.pollIntervalSeconds = $0; store.scheduleTimer() })
    }
}
