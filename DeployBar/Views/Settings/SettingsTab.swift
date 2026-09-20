import Foundation
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

/// Shared by the welcome window and the Settings scene so deep links select
/// the right pane even when Settings has not been opened yet.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selection: SettingsTab = .general
    @ObservationIgnored var openSettings: (() -> Void)?

    func showAccounts() {
        selection = .accounts
        openSettings?()
    }
}
