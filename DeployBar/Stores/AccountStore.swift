import Foundation
import Observation

@Observable
@MainActor
final class AccountStore {
    private(set) var accounts: [Account] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let reloadCLIToken: () -> String?
    @ObservationIgnored private let reloadGitHubToken: () -> String?

    private enum Keys { static let accounts = "connectedAccounts" }

    init(defaults: UserDefaults = .standard,
         credentials: CredentialStore = KeychainCredentialStore(),
         detectCLI: () -> Bool = { (try? TokenProvider().credentials()) != nil },
         reloadCLIToken: @escaping () -> String? = { try? TokenProvider().credentials().token },
         detectGitHubCLI: () -> Bool = { GitHubTokenProvider().token() != nil },
         reloadGitHubToken: @escaping () -> String? = { GitHubTokenProvider().token() }) {
        self.defaults = defaults
        self.credentials = credentials
        self.reloadCLIToken = reloadCLIToken
        self.reloadGitHubToken = reloadGitHubToken
        self.accounts = Self.load(defaults)

        if detectCLI(), cliAccount == nil {
            let cli = Account.vercelCLI(id: UUID(), label: "Vercel CLI")
            accounts.insert(cli, at: 0)
            persist()
        }
        if detectGitHubCLI(), githubCLIAccount == nil {
            let gh = Account.githubCLI(id: UUID(), label: "GitHub CLI")
            accounts.append(gh)
            persist()
        }
    }

    /// The detected Vercel CLI account, if present.
    var cliAccount: Account? { accounts.first { $0.source == .vercelCLI } }
    /// The detected GitHub CLI (`gh`) account, if present.
    var githubCLIAccount: Account? { accounts.first { $0.source == .githubCLI } }

    func token(for account: Account) -> String? {
        switch account.source {
        case .vercelCLI:            return reloadCLIToken()
        case .githubCLI:            return reloadGitHubToken()
        case .keychain(let name):   return credentials.token(for: name)
        }
    }

    @discardableResult
    func addKeychainAccount(provider: Provider, label: String, token: String) -> Account {
        let kcName = "acct-\(UUID().uuidString)"
        credentials.setToken(token, for: kcName)
        let acct = Account(id: UUID(), provider: provider, label: label,
                           source: .keychain(account: kcName))
        accounts.append(acct)
        persist()
        return acct
    }

    func removeAccount(_ account: Account) {
        if case .keychain(let name) = account.source { credentials.removeToken(for: name) }
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Keys.accounts)
    }

    private static func load(_ defaults: UserDefaults) -> [Account] {
        guard let data = defaults.data(forKey: Keys.accounts),
              let decoded = try? JSONDecoder().decode([Account].self, from: data)
        else { return [] }
        return decoded
    }
}
