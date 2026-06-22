import SwiftUI

@main
struct VercelBarApp: App {
    @State private var store: DeploymentStore
    @State private var settings: SettingsStore
    private let credentials: VercelCredentials

    init() {
        let settings = SettingsStore()
        let provider = TokenProvider()
        let creds = (try? provider.credentials()) ?? VercelCredentials(token: "", teamId: nil)

        // Honor a previously-selected team ("__personal__" means personal scope).
        let persisted = settings.selectedTeamId
        let effectiveTeamId: String?
        if persisted == "__personal__" { effectiveTeamId = nil }
        else if let persisted { effectiveTeamId = persisted }
        else { effectiveTeamId = creds.teamId }  // first launch: CLI default

        let effectiveCreds = VercelCredentials(token: creds.token, teamId: effectiveTeamId)
        self.credentials = effectiveCreds
        let client = VercelClient(credentials: effectiveCreds)
        let initialScopeName = effectiveTeamId ?? "personal"
        let store = DeploymentStore(client: client, settings: settings, scopeName: initialScopeName)
        _store = State(initialValue: store)
        _settings = State(initialValue: settings)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
                .task {
                    store.start()
                    let resolved = await ScopeResolver.scopeName(credentials: credentials)
                    // Update the store's scopeName so the header reflects the resolved name.
                    // currentTeamId stays unchanged (personal/team set at init).
                    store.scopeName = resolved
                }
        } label: {
            MenuBarIcon(state: store.iconState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, store: store)
        }
    }
}

/// Wrapper view that gives access to `@Environment(\.openSettings)` for the Settings button.
private struct MenuBarContentView: View {
    @Environment(\.openSettings) private var openSettings
    let store: DeploymentStore

    var body: some View {
        PopoverView(store: store) {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}
