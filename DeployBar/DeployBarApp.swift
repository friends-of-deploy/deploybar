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

        // The menu bar icon and its panel are AppKit-owned now — see
        // `MenuBarPanelController` for why `MenuBarExtra` had to go. The
        // delegate builds them once the app has finished launching, so it needs
        // closures rather than the values themselves: `@NSApplicationDelegateAdaptor`
        // constructs the delegate before this initializer's `@State` exists.
        appDelegate.makePanel = { [appDelegate] in
            MenuBarPanelController(
                content: PopoverView(store: store) {
                    NSApp.activate(ignoringOtherApps: true)
                    appDelegate.openSettings()
                },
                onRightClick: { button in appDelegate.showContextMenu(for: button) })
        }
        appDelegate.currentIconState = { store.iconState }
    }

    var body: some Scene {
        Settings {
            SettingsView(settings: settings, store: store, accountStore: accountStore, updater: updater)
        }
    }
}
