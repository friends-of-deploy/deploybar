import SwiftUI

@main
struct VercelBarApp: App {
    @State private var store: DeploymentStore
    @State private var settings: SettingsStore
    @State private var accountStore: AccountStore

    init() {
        let settings = SettingsStore()
        let accountStore = AccountStore()
        if let cli = accountStore.cliAccount {
            settings.migrateLegacyFollowData(cliAccountId: cli.id)
        }
        let store = DeploymentStore(accountStore: accountStore, settings: settings)
        _settings = State(initialValue: settings)
        _accountStore = State(initialValue: accountStore)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
                .task {
                    store.start()
                }
        } label: {
            MenuBarIcon(state: store.iconState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, store: store, accountStore: accountStore)
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
