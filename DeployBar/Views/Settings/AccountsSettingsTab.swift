import SwiftUI

/// The account manager, System-Settings style: the account list as a boxed
/// sidebar on the left, the selection's detail filling the right pane.
/// Per-account project follow settings live inside that detail, so there is
/// no separate Projects tab.
struct AccountsSettingsTab: View {
    let settings: SettingsStore
    let store: DeploymentStore
    let accountStore: AccountStore

    /// What the right pane shows. A pending "add" is a selection state of its
    /// own so the form can replace the detail without a sheet.
    private enum Selection: Hashable {
        case account(UUID)
        case newAccount
    }

    @State private var selection: Selection?
    @State private var confirmingRemoval = false
    /// Mirrored here so picking a color repaints the sidebar immediately —
    /// `SettingsStore` reads through to `UserDefaults` and isn't observable.
    @State private var scopeColors: [String: Int] = [:]

    private var selectedAccount: Account? {
        guard case .account(let id) = resolvedSelection else { return nil }
        return accountStore.accounts.first { $0.id == id }
    }

    /// Falls back to the first account so the pane is never blank before the
    /// user has touched the list, or after a removal drops the selected id.
    private var resolvedSelection: Selection? {
        if case .account(let id) = selection,
           !accountStore.accounts.contains(where: { $0.id == id }) {
            return accountStore.accounts.first.map { .account($0.id) }
        }
        if selection == nil { return accountStore.accounts.first.map { .account($0.id) } }
        return selection
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            accountBox
                .frame(width: 232)

            detail
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .onAppear { scopeColors = settings.scopeColorOverrides }
    }

    // MARK: Sidebar

    private var accountBox: some View {
        SettingsListBox {
            List(selection: Binding(get: { resolvedSelection },
                                    set: { selection = $0 })) {
                ForEach(accountStore.accounts) { account in
                    row(for: account).tag(Selection.account(account.id))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        } accessory: {
            SettingsStripButton(
                systemImage: "plus",
                help: String(localized: "Add account", comment: "Add account tooltip")
            ) {
                selection = .newAccount
            }

            Divider()
                .frame(height: 14)

            SettingsStripButton(
                systemImage: "minus",
                help: String(localized: "Remove account", comment: "Remove account tooltip"),
                // CLI-backed accounts are auto-detected; removing them in the
                // UI would just have them reappear on the next launch.
                isDisabled: selectedAccount?.isReadOnly ?? true
            ) {
                confirmingRemoval = true
            }
            .confirmationDialog(
                String(localized: "Remove this account?", comment: "Remove account confirmation"),
                isPresented: $confirmingRemoval
            ) {
                Button(String(localized: "Remove", comment: "Remove account button"),
                       role: .destructive, action: removeSelected)
            }
        }
    }

    private func row(for account: Account) -> some View {
        let projects = store.allSourcedProjects.filter { $0.account.id == account.id }
        let followed = projects.filter { store.isFollowed($0) }.count
        return HStack(spacing: 8) {
            ScopeColorPicker(scopeId: ScopeRef(accountId: account.id, teamId: nil).id,
                             allScopeIds: store.allScopeIds,
                             settings: settings,
                             overrides: $scopeColors)
            Image(systemName: account.provider.iconName)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(projects.isEmpty
                     ? Self.sourceCaption(for: account)
                     : String(localized: "\(followed) of \(projects.count) followed",
                              comment: "Accounts sidebar follow count"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(account.provider.displayName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 2)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch resolvedSelection {
        case .newAccount:
            AddAccountForm(accountStore: accountStore) { added in
                selection = .account(added.id)
            }
        case .account:
            if let account = selectedAccount {
                // `.id` re-creates the detail (and its @State segment and
                // filter) when the selection moves to another account.
                AccountDetailView(settings: settings, store: store, account: account)
                    .id(account.id)
            } else {
                emptyState
            }
        case nil:
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(String(localized: "No accounts connected.", comment: "Accounts empty state"))
                .foregroundStyle(.secondary)
            Button(String(localized: "Add account", comment: "Add account button")) {
                selection = .newAccount
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func removeSelected() {
        guard let account = selectedAccount, !account.isReadOnly else { return }
        accountStore.removeAccount(account)
        selection = accountStore.accounts.first.map { .account($0.id) }
        // The popover caches rows per source; without this the removed account's
        // projects keep showing until some later poll happens to overwrite the
        // snapshot — and if this was the last account, forever.
        Task { await store.accountsChanged() }
    }

    static func sourceCaption(for account: Account) -> String {
        switch account.source {
        case .vercelCLI: return String(localized: "From Vercel CLI", comment: "CLI account source caption")
        case .githubCLI: return String(localized: "From GitHub CLI", comment: "CLI account source caption")
        case .keychain:  return String(localized: "Token", comment: "Keychain account source caption")
        }
    }
}

/// The add-account form, shown in the detail pane while "+" is pending.
private struct AddAccountForm: View {
    let accountStore: AccountStore
    let onAdded: (Account) -> Void

    @State private var provider: Provider = Provider.allCases.first(where: \.isImplemented) ?? .vercel
    @State private var label = ""
    @State private var token = ""

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Provider", comment: "Add account provider picker"),
                       selection: $provider) {
                    ForEach(Provider.allCases.filter(\.isImplemented), id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField(String(localized: "Label (optional)", comment: "Add account label field"),
                          text: $label,
                          prompt: Text(provider.displayName))
                SecureField(String(localized: "Token", comment: "Add account token field"),
                            text: $token)
            } header: {
                Text(String(localized: "Add account", comment: "Accounts tab add-account section header"))
            } footer: {
                Text(String(localized: "DeployBar reuses your Vercel CLI login. Run `vercel login` in Terminal to sign in.",
                            comment: "Accounts tab CLI login guidance footer"))
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button(String(localized: "Add", comment: "Add account button"), action: add)
                        .buttonStyle(.borderedProminent)
                        .disabled(token.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let resolved = label.isEmpty ? provider.displayName : label
        let account = accountStore.addKeychainAccount(provider: provider,
                                                      label: resolved,
                                                      token: token)
        label = ""
        token = ""
        onAdded(account)
    }
}
