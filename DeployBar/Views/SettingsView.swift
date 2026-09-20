import SwiftUI

/// Tabbed settings window.
///
/// Inside a `Settings` scene, `TabView` renders macOS's native preference
/// toolbar — an icon above each label, with the window title tracking the
/// selected tab. The same `TabView` in a plain `Window` scene falls back to a
/// content-style strip that drops the icons, which is why the scene type
/// matters here. Each tab owns its own `Form`; this type only composes them.
struct SettingsView: View {
    let settings: SettingsStore
    let store: DeploymentStore
    let accountStore: AccountStore
    let updater: UpdaterController
    var openOnboarding: () -> Void = {}
    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.selection) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbolName) }
                    .tag(tab)
            }
        }
        // One fixed size for every tab. Height on the TabView, not inside a
        // tab: the window opens at the FIRST tab's natural height, so a short
        // General page would open the window small and it would only grow
        // after visiting Projects. The taller panes fill this instead.
        .frame(width: 680, height: 480)
        .background(SettingsDockPresence())
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab(settings: settings, store: store, openOnboarding: openOnboarding)
        case .notifications:
            NotificationSettingsTab(settings: settings)
        case .updates:
            UpdatesSettingsTab(updater: updater)
        case .accounts:
            AccountsSettingsTab(settings: settings, store: store, accountStore: accountStore)
        }
    }
}

/// Keep the Dock icon for the lifetime of the settings window, including when
/// it loses focus or is minimized. SwiftUI can reuse the window after closing.
private struct SettingsDockPresence: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {}

    final class TrackerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            notifications.removeObserver(self)
            guard let window else { return }

            notifications.addObserver(self, selector: #selector(showDockIcon),
                                      name: NSWindow.didBecomeKeyNotification, object: window)
            notifications.addObserver(self, selector: #selector(hideDockIcon),
                                      name: NSWindow.willCloseNotification, object: window)
            if window.isVisible {
                showDockIcon()
            }
        }

        @objc private func showDockIcon() {
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
        }

        @objc private func hideDockIcon() {
            NSApp.setActivationPolicy(.accessory)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
