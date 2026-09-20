import SwiftUI

@main
struct DeployBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var store: DeploymentStore
    @State private var settings: SettingsStore
    @State private var accountStore: AccountStore
    @State private var updater: UpdaterController
    @State private var onboarding: OnboardingWindowController
    @State private var crashReporting: CrashReportingController?

    init() {
        // Demo mode: an invented world for documentation screenshots, off unless
        // DEPLOYBAR_DEMO=1. Everything below this branch — views, aggregation,
        // polling — is the production path, so a screenshot shows the real app
        // rather than a mock-up.
        if let demo = DemoEnvironment.buildFromEnvironment() {
            _crashReporting = State(initialValue: nil)
            let store = DeploymentStore(accountStore: demo.accountStore,
                                        settings: demo.settings,
                                        makeClient: demo.makeClient)
            store.teams = demo.teams
            _settings = State(initialValue: demo.settings)
            _accountStore = State(initialValue: demo.accountStore)
            _store = State(initialValue: store)
            _updater = State(initialValue: UpdaterController(settings: demo.settings))
            let state = OnboardingState(defaults: UserDefaults(suiteName: "io.eightlines.deploybar.onboarding-preview")!)
            let welcome = OnboardingWindowController(state: state, accounts: demo.accountStore, store: store,
                                                     settings: demo.settings)
            _onboarding = State(initialValue: welcome)
            if ProcessInfo.processInfo.environment["DEPLOYBAR_ONBOARDING"] == "1" {
                DispatchQueue.main.async { welcome.present() }
            }
            store.start()
            return
        }

        let settings = SettingsStore()
        _crashReporting = State(initialValue: CrashReportingController(settings: settings))
        let accountStore = AccountStore()
        if let cli = accountStore.cliAccount {
            settings.migrateLegacyFollowData(cliAccountId: cli.id)
        }
        let store = DeploymentStore(accountStore: accountStore, settings: settings)
        _settings = State(initialValue: settings)
        _accountStore = State(initialValue: accountStore)
        _store = State(initialValue: store)
        _updater = State(initialValue: UpdaterController(settings: settings))
        let state = OnboardingState()
        let welcome = OnboardingWindowController(state: state, accounts: accountStore, store: store,
                                                 settings: settings)
        _onboarding = State(initialValue: welcome)
        if state.shouldPresentAutomatically(hasAccounts: accountStore.hadPersistedAccounts) {
            DispatchQueue.main.async { welcome.present() }
        }
        // Start polling at launch. Notification permission is requested in context.
        // The popover's `.task` runs only when the menu bar item is first
        // opened, so relying on it alone meant a user who never opened the
        // popover got no background polling and no notifications.
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store, openOnboarding: { onboarding.present() })
                .task {
                    store.start()
                }
        } label: {
            MenuBarLabel(state: store.iconState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, store: store, accountStore: accountStore, updater: updater, openOnboarding: { onboarding.present() })
        }
    }
}

/// Wrapper view that gives access to `@Environment(\.openSettings)` for the Settings button.
private struct MenuBarContentView: View {
    @Environment(\.openSettings) private var openSettings
    let store: DeploymentStore
    let openOnboarding: () -> Void

    var body: some View {
        PopoverView(store: store, openSettings: {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }, openOnboarding: openOnboarding)
    }
}

/// Capture the Settings action from a SwiftUI scene that is present at launch.
/// The welcome window is hosted by AppKit and has no scene environment of its own.
private struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings
    let state: IconState

    var body: some View {
        MenuBarIcon(state: state)
            .onAppear {
                SettingsNavigation.shared.openSettings = {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
    }
}
