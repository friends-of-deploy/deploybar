import SwiftUI

struct SettingsView: View {
    let settings: SettingsStore
    let store: DeploymentStore
    let accountStore: AccountStore

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, store: store)
                .tabItem { Label(String(localized: "General", comment: "Settings tab title"), systemImage: "gearshape") }

            NotificationSettingsTab(settings: settings)
                .tabItem { Label(String(localized: "Notifications", comment: "Settings tab title"), systemImage: "bell") }

            ProjectsSettingsTab(settings: settings, store: store)
                .tabItem { Label(String(localized: "Projects", comment: "Settings tab title"), systemImage: "square.stack.3d.up") }

            AccountsSettingsTab(accountStore: accountStore)
                .tabItem { Label(String(localized: "Accounts", comment: "Settings tab title"), systemImage: "person.2.crop.square.stack") }
        }
        .frame(width: 540)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let settings: SettingsStore
    let store: DeploymentStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Refresh status", comment: "Poll interval picker label"), selection: intervalBinding) {
                    Text("Every 10 seconds").tag(10)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 5 minutes").tag(300)
                }
            } footer: {
                Text("How often DeployBar checks Vercel for new deployment activity.")
            }

            Section {
                Toggle(String(localized: "Launch at login", comment: "Launch at login toggle"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LaunchAtLogin.set($0) }))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 240)
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { settings.pollIntervalSeconds },
                set: { settings.pollIntervalSeconds = $0; store.scheduleTimer() })
    }
}

// MARK: - Notifications

private struct NotificationSettingsTab: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Failed deployments", comment: "Notification toggle"), isOn: bind(\.notifyOnFailure))
                Toggle(String(localized: "Successful deployments", comment: "Notification toggle"), isOn: bind(\.notifyOnSuccess))
                Toggle(String(localized: "Started deployments", comment: "Notification toggle"), isOn: bind(\.notifyOnStarted))
                Toggle(String(localized: "Canceled deployments", comment: "Notification toggle"), isOn: bind(\.notifyOnCanceled))
            } header: {
                Text("Notify me about")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 240)
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }
}

// MARK: - Projects (follow)

private struct ProjectsSettingsTab: View {
    let settings: SettingsStore
    let store: DeploymentStore
    @State private var query = ""

    /// All projects (across accounts), alphabetical, narrowed by the filter field.
    private var filtered: [SourcedProject] {
        let all = store.allSourcedProjects
            .sorted { $0.project.name.localizedCaseInsensitiveCompare($1.project.name) == .orderedAscending }
        guard !query.isEmpty else { return all }
        return all.filter { $0.project.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Automatically follow new projects", comment: "Auto-follow toggle"),
                    isOn: Binding(
                        get: { settings.autoFollowNewProjects },
                        set: { settings.autoFollowNewProjects = $0 }
                    )
                )
            }

            if store.allSourcedProjects.isEmpty {
                Section(String(localized: "Projects", comment: "Projects tab section header")) {
                    Text(String(localized: "No projects loaded yet.", comment: "Projects tab empty state"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField(
                        String(localized: "Filter projects", comment: "Projects tab filter field placeholder"),
                        text: $query
                    )
                }

                // One section per account, so long multi-source lists stay scannable.
                ForEach(store.connectedAccounts) { account in
                    let items = filtered.filter { $0.account.id == account.id }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { sp in
                                Toggle(sp.project.name, isOn: Binding(
                                    get: { store.isFollowed(sp) },
                                    set: { store.setFollowed(sp, $0) }
                                ))
                            }
                        } header: {
                            Text(account.label)
                        }
                    }
                }

                if !query.isEmpty, filtered.isEmpty {
                    Section {
                        Text(String(localized: "No projects match “\(query)”.", comment: "Projects tab filter empty state"))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                } footer: {
                    Text(String(localized: "Unfollowed projects are hidden from the menu and never notify.", comment: "Projects tab footer"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

// MARK: - Accounts

private struct AccountsSettingsTab: View {
    let accountStore: AccountStore

    @State private var newProvider: Provider = Provider.allCases.first(where: \.isImplemented) ?? .vercel
    @State private var newLabel: String = ""
    @State private var newToken: String = ""

    private func sourceCaption(for account: Account) -> String {
        switch account.source {
        case .vercelCLI:  return String(localized: "From Vercel CLI", comment: "CLI account source caption")
        case .githubCLI:  return String(localized: "From GitHub CLI", comment: "CLI account source caption")
        case .keychain:   return String(localized: "Token", comment: "Keychain account source caption")
        }
    }

    var body: some View {
        Form {
            ForEach(Provider.allCases.filter { provider in
                accountStore.accounts.contains { $0.provider == provider }
            }, id: \.self) { provider in
                Section {
                    ForEach(accountStore.accounts.filter { $0.provider == provider }) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.label)
                                Text(sourceCaption(for: account))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !account.isReadOnly {
                                Button(String(localized: "Remove", comment: "Remove account button")) {
                                    accountStore.removeAccount(account)
                                }
                                .foregroundStyle(.red)
                            }
                        }
                    }
                } header: {
                    Text(provider.displayName)
                }
            }

            Section {
                Picker(String(localized: "Provider", comment: "Add account provider picker"), selection: $newProvider) {
                    ForEach(Provider.allCases.filter(\.isImplemented), id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField(
                    String(localized: "Label (optional)", comment: "Add account label field"),
                    text: $newLabel
                )
                SecureField(
                    String(localized: "Token", comment: "Add account token field"),
                    text: $newToken
                )
                Button(String(localized: "Add", comment: "Add account button")) {
                    let resolvedLabel = newLabel.isEmpty ? newProvider.displayName : newLabel
                    accountStore.addKeychainAccount(provider: newProvider, label: resolvedLabel, token: newToken)
                    newLabel = ""
                    newToken = ""
                }
                .disabled(newToken.isEmpty)
            } header: {
                Text(String(localized: "Add account", comment: "Accounts tab add-account section header"))
            } footer: {
                Text(String(localized: "DeployBar reuses your Vercel CLI login. Run `vercel login` in Terminal to sign in.", comment: "Accounts tab CLI login guidance footer"))
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}
