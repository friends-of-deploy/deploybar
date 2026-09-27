import AppKit
import Observation

/// The settings window's tabs, in display order.
///
/// A plain model rather than an inline list so the toolbar and the content
/// switch cannot drift apart, and so the pairing of tab to icon and label is
/// unit testable.
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case notifications
    case accounts
    // Last: the tab a user opens once in a while, after the ones they live in.
    case updates

    var id: String { rawValue }

    /// SF Symbol shown above the tab's title.
    var symbolName: String {
        switch self {
        case .general:       return "gearshape"
        case .notifications: return "bell"
        case .updates:       return "arrow.down.circle"
        case .accounts:      return "person.2.crop.square.stack"
        }
    }

    var title: String {
        switch self {
        case .general:
            return String(localized: "General", comment: "Settings tab title")
        case .notifications:
            return String(localized: "Notifications", comment: "Settings tab title")
        case .updates:
            return String(localized: "Updates", comment: "Settings tab title")
        case .accounts:
            return String(localized: "Accounts", comment: "Settings tab title")
        }
    }
}

/// The one way to open Settings, shared by the popover, the menu bar icon's
/// context menu and the welcome window, so deep links select the right pane
/// even when Settings has not been opened yet.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selection: SettingsTab = .general
    /// SwiftUI's `openSettings` action, captured from a scene that has one.
    /// It is the only supported way in: since macOS 14 the old
    /// `showSettingsWindow:` selector just logs "Please use SettingsLink for
    /// opening the Settings scene." and opens nothing.
    @ObservationIgnored var openSettings: (() -> Void)?
    /// The Settings window once it exists; see `SettingsDockPresence`.
    @ObservationIgnored weak var window: NSWindow?

    func open() {
        guard let openSettings else { return }
        // A menu bar (accessory) app's new window opens behind the frontmost
        // app, which reads as Settings not opening at all. Become a regular
        // app first, then activate, then open; `SettingsDockPresence` goes
        // back to accessory when the window closes.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        // A reused window is already known; a new one registers itself during
        // this pass, so bring it forward on the next one.
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func showAccounts() {
        selection = .accounts
        open()
    }
}
