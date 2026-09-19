import SwiftUI

/// One account's organizations: which are on, and what colour each marks its
/// rows with.
///
/// An account can belong to dozens of organizations, so this is its own tab
/// rather than a section of Information — and it carries a filter for the same
/// reason `AccountProjectsForm` does.
struct AccountOrganizationsForm: View {
    let settings: SettingsStore
    let store: DeploymentStore
    let account: Account

    @State private var query = ""
    /// Mirrors the persisted overrides so a pick repaints at once;
    /// `SettingsStore` reads through to `UserDefaults` and isn't observable.
    @State private var scopeColors: [String: Int] = [:]
    /// Mirrors the disabled set for the same reason.
    @State private var disabled: Set<String> = []

    private var organizations: [Team] { store.organizations(for: account) }

    private var filtered: [Team] { Self.filter(organizations, query: query) }

    /// Organizations matching the filter, by display name. Static and pure so
    /// the matching is testable without standing up a store.
    static func filter(_ organizations: [Team], query: String) -> [Team] {
        guard !query.isEmpty else { return organizations }
        return organizations.filter {
            ($0.name ?? $0.slug ?? $0.id).localizedCaseInsensitiveContains(query)
        }
    }

    private var accountColorIndex: Int {
        store.scopeColorIndex(accountId: account.id, teamId: nil)
    }

    var body: some View {
        Form {
            if organizations.isEmpty {
                Section {
                    Text(String(localized: "No organizations found for this account.",
                                comment: "Organizations tab empty state"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField(String(localized: "Filter organizations",
                                     comment: "Organizations tab filter placeholder"),
                              text: $query)
                } footer: {
                    Text(refreshCaption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(filtered) { org in
                        row(for: org)
                    }
                } footer: {
                    Text(String(localized: "A disabled organization is hidden from the menu, never notifies, and is not fetched.",
                                comment: "Organizations tab footer"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            scopeColors = settings.scopeColorOverrides
            disabled = settings.disabledScopeIds
        }
    }

    private func row(for org: Team) -> some View {
        let scopeId = ScopeRef(accountId: account.id, teamId: org.id).id
        return HStack(spacing: 8) {
            ScopeColorPicker(scopeId: scopeId,
                             allScopeIds: store.allScopeIds,
                             settings: settings,
                             overrides: $scopeColors,
                             automaticIndex: accountColorIndex)
            Toggle(org.name ?? org.slug ?? org.id, isOn: Binding(
                get: { !disabled.contains(scopeId) },
                set: { enabled in
                    settings.setScopeEnabled(enabled, for: scopeId)
                    disabled = settings.disabledScopeIds
                    store.scopeEnablementChanged(accountId: account.id, teamId: org.id)
                }))
        }
    }

    /// Names the cost of what is enabled: with many organizations on, each one
    /// refreshes less often, and that is better stated than discovered.
    private var refreshCaption: String {
        let interval = store.effectiveRefreshInterval(for: account)
        let enabled = organizations.filter {
            settings.isScopeEnabled(ScopeRef(accountId: account.id, teamId: $0.id).id)
        }.count
        if interval <= settings.pollIntervalSeconds {
            return String(localized: "\(enabled) of \(organizations.count) organizations enabled.",
                          comment: "Organizations tab refresh caption")
        }
        let minutes = Int((Double(interval) / 60).rounded())
        return minutes >= 1
            ? String(localized: "\(enabled) of \(organizations.count) enabled · refreshing every ~\(minutes) min.",
                     comment: "Organizations tab refresh caption with interval")
            : String(localized: "\(enabled) of \(organizations.count) enabled · refreshing every ~\(interval) s.",
                     comment: "Organizations tab refresh caption with seconds")
    }
}
