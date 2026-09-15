import SwiftUI

/// What version is installed, when the app last looked for a newer one, and
/// which stream it looks in.
struct UpdatesSettingsTab: View {
    @Bindable var updater: UpdaterController

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Version", comment: "About row label"),
                               value: AppInfo.version)
                LabeledContent(String(localized: "Build", comment: "About row label"),
                               value: AppInfo.build)
                LabeledContent(String(localized: "Last checked", comment: "Update status row label")) {
                    Text(lastCheckedDescription)
                        .foregroundStyle(.secondary)
                }
                Button(String(localized: "Check for Updates Now", comment: "Update check button")) {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .disabled(!updater.canCheckForUpdates)
            }

            Section {
                Toggle(String(localized: "Check automatically", comment: "Automatic update check toggle"),
                       isOn: $updater.automaticallyChecksForUpdates)
                Toggle(String(localized: "Download updates in the background",
                              comment: "Automatic update download toggle"),
                       isOn: $updater.automaticallyDownloadsUpdates)
                    // Downloading automatically is meaningless if the app never
                    // looks, so the second switch follows the first.
                    .disabled(!updater.automaticallyChecksForUpdates)
            }

            Section {
                Picker(String(localized: "Channel", comment: "Update channel picker label"),
                       selection: $updater.channel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
            } footer: {
                Text(String(localized: "Beta releases arrive earlier and may be unstable. Switching back to Stable keeps the installed build until the next stable release.",
                            comment: "Update channel picker footer"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheckedDescription: String {
        guard let date = updater.lastUpdateCheckDate else {
            return String(localized: "Never", comment: "Shown when the app has not checked for updates yet")
        }
        return date.formatted(.relative(presentation: .named))
    }
}
