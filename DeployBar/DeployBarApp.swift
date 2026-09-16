import SwiftUI

@main
struct DeployBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var store: DeploymentStore
    @State private var settings: SettingsStore
    @State private var accountStore: AccountStore
    @State private var updater: UpdaterController

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
        _updater = State(initialValue: UpdaterController(settings: settings))
        // Start polling (and request notification authorization) at launch.
        // The popover's `.task` runs only when the menu bar item is first
        // opened, so relying on it alone meant a user who never opened the
        // popover got no background polling and no notifications.
        store.start()
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
            SettingsView(settings: settings, store: store, accountStore: accountStore, updater: updater)
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
