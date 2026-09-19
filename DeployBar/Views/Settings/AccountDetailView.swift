import SwiftUI

/// Which slice of an account's settings the detail pane shows. Segments keep
/// the pane short instead of one long scroll.
enum AccountDetailTab: String, CaseIterable, Identifiable, Sendable {
    case information
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .information:
            return String(localized: "Information", comment: "Account detail segment title")
        case .projects:
            return String(localized: "Projects", comment: "Account detail segment title")
        }
    }
}

/// Everything about ONE account, segmented Mail-style: identity and
/// credential source, then which of its projects reach the menu.
struct AccountDetailView: View {
    let settings: SettingsStore
    let store: DeploymentStore
    let account: Account

    @State private var tab: AccountDetailTab = .information
    /// Mirrors the persisted overrides so a pick repaints the swatches at once;
    /// `SettingsStore` reads through to `UserDefaults` and isn't observable.
    @State private var scopeColors: [String: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(AccountDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Fills the pane's width like the tab strip above it, rather than
            // shrinking to its labels and floating in the middle.
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Group {
                switch tab {
                case .information:
                    informationForm
                case .projects:
                    AccountProjectsForm(settings: settings, store: store, account: account)
                }
            }
            // Keep a fixed gap below the tabs even when the form scrolls.
            .clipped()
            .padding(.top, 12)
        }
    }

    /// Read-only: tokens are write-once into the Keychain, so re-authenticating
    /// means removing the account and adding it again.
    private var informationForm: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Name", comment: "Account detail label"),
                               value: account.label)
                LabeledContent(String(localized: "Provider", comment: "Account detail label"),
                               value: account.provider.displayName)
                LabeledContent(String(localized: "Credential", comment: "Account detail label"),
                               value: AccountsSettingsTab.sourceCaption(for: account))
            } footer: {
                Text(account.isReadOnly
                     ? String(localized: "Detected from your CLI login. Sign out in Terminal to disconnect it.",
                              comment: "Read-only account footer")
                     : String(localized: "Stored in your Keychain. To replace the token, remove this account and add it again.",
                              comment: "Keychain account footer"))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(String(localized: "Projects", comment: "Account detail label"),
                               value: "\(followedCount) / \(projects.count)")
            } footer: {
                Text(String(localized: "Followed projects out of all the ones this account can see.",
                            comment: "Account project count footer"))
                    .foregroundStyle(.secondary)
            }

            Section {
                // One row per scope: the account itself, plus every team it can
                // reach. Each is a separate source in "All sources", so each
                // carries its own marker.
                ForEach(store.scopes(for: account)) { scope in
                    LabeledContent(scope.teamName ?? account.label) {
                        ScopeColorPicker(
                            scopeId: ScopeRef(accountId: account.id, teamId: scope.teamId).id,
                            allScopeIds: store.allScopeIds,
                            settings: settings,
                            overrides: $scopeColors
                        )
                    }
                }
            } header: {
                Text(String(localized: "Marker color", comment: "Account detail section header"))
            } footer: {
                Text(String(localized: "The dot shown next to rows from this source in All sources. Automatic picks a color from the source's identity.",
                            comment: "Marker color section footer"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { scopeColors = settings.scopeColorOverrides }
    }

    private var projects: [SourcedProject] {
        store.allSourcedProjects.filter { $0.account.id == account.id }
    }

    private var followedCount: Int {
        projects.filter { store.isFollowed($0) }.count
    }
}

/// One account's projects, narrowed to a single organization first.
///
/// An account can see hundreds of repositories; a `Form` renders every row it
/// is given, so listing them all at once is what makes this pane crawl. The
/// organization picker keeps the rendered list to one owner at a time.
struct AccountProjectsForm: View {
    let settings: SettingsStore
    let store: DeploymentStore
    let account: Account

    /// Reset with the view when the selection moves to another account, so a
    /// stale filter never hides the new account's projects.
    @State private var query = ""
    @State private var organization: String?

    /// Projects with no repository link (a Vercel project that was never
    /// connected to git) still need a home in the picker.
    static let unlinkedKey = ""

    private var projects: [SourcedProject] {
        store.allSourcedProjects.filter { $0.account.id == account.id }
    }

    private var organizations: [String] { Self.organizations(of: projects) }

    /// Every owner in the given projects, alphabetical, with the unlinked
    /// bucket last so it never becomes the default selection.
    ///
    /// Static and pure so the grouping the picker depends on is testable
    /// without standing up a store.
    static func organizations(of projects: [SourcedProject]) -> [String] {
        let owners = Set(projects.map { $0.project.repoOrg ?? unlinkedKey })
        return owners.filter { $0 != unlinkedKey }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        } + (owners.contains(unlinkedKey) ? [unlinkedKey] : [])
    }

    /// Falls back to the first organization so the pane is never blank before
    /// the user has touched the picker, or after a refresh drops the selection.
    private var resolvedOrganization: String? {
        if let organization, organizations.contains(organization) { return organization }
        return organizations.first
    }

    private var organizationProjects: [SourcedProject] {
        guard let resolvedOrganization else { return [] }
        return Self.projects(projects, in: resolvedOrganization)
    }

    /// One owner's projects, alphabetical. Static and pure for the same
    /// reason as `organizations(of:)`.
    static func projects(_ projects: [SourcedProject], in organization: String) -> [SourcedProject] {
        projects
            .filter { ($0.project.repoOrg ?? unlinkedKey) == organization }
            .sorted { $0.project.name.localizedCaseInsensitiveCompare($1.project.name) == .orderedAscending }
    }

    private var filtered: [SourcedProject] {
        guard !query.isEmpty else { return organizationProjects }
        return organizationProjects.filter { $0.project.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Automatically follow new projects",
                              comment: "Auto-follow toggle"),
                       isOn: Binding(get: { settings.autoFollowNewProjects },
                                     set: { settings.autoFollowNewProjects = $0 }))
            } footer: {
                Text(String(localized: "Unfollowed projects are hidden from the menu and never notify.",
                            comment: "Projects tab footer"))
                    .foregroundStyle(.secondary)
            }

            if projects.isEmpty {
                Section {
                    Text(String(localized: "No projects loaded yet.", comment: "Projects tab empty state"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker(String(localized: "Organization", comment: "Project organization picker label"),
                           selection: Binding(get: { resolvedOrganization },
                                              set: { organization = $0 })) {
                        ForEach(organizations, id: \.self) { org in
                            Text(Self.label(for: org, projects: projects))
                                .tag(Optional(org))
                        }
                    }
                }

                // Its own section: the filter narrows the list below, it is not
                // part of choosing an organization.
                Section {
                    TextField(String(localized: "Filter projects",
                                     comment: "Projects tab filter field placeholder"),
                              text: $query)
                }

                if filtered.isEmpty {
                    Section {
                        Text(query.isEmpty
                             ? String(localized: "This organization has no projects.",
                                      comment: "Organization empty state")
                             : String(localized: "No projects match \u{201C}\(query)\u{201D}.",
                                      comment: "Projects tab filter empty state"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // No header: the organization picker above already names
                    // the owner and its project count.
                    Section {
                        ForEach(filtered) { sp in
                            Toggle(sp.project.name, isOn: Binding(
                                get: { store.isFollowed(sp) },
                                set: { store.setFollowed(sp, $0) }))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // A filter carried over from another owner would show an empty list
        // for no visible reason.
        .onChange(of: resolvedOrganization) { _, _ in query = "" }
    }

    /// The picker's row: the owner plus how many of its projects are followed.
    static func label(for organization: String, projects: [SourcedProject]) -> String {
        let owned = projects.filter { ($0.project.repoOrg ?? unlinkedKey) == organization }
        let name = organization.isEmpty
            ? String(localized: "Not linked to a repository", comment: "Unlinked project group")
            : organization
        return "\(name) (\(owned.count))"
    }
}
