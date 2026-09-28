import Foundation
import Observation

@Observable
@MainActor
final class AccountStore {
    private(set) var accounts: [Account] = []
    let hadPersistedAccounts: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStore
    /// One per credential source, in detection order.
    @ObservationIgnored let strategies: [CredentialStrategy]

    private enum Keys { static let accounts = "connectedAccounts" }

    /// Production and most tests: the three real sources, configured by closure.
    convenience init(defaults: UserDefaults = .standard,
                     credentials: CredentialStore = KeychainCredentialStore(),
                     detectCLI: @escaping () -> Bool = { (try? TokenProvider().credentials()) != nil },
                     reloadCLIToken: @escaping () -> String? = { try? TokenProvider().credentials().token },
                     detectGitHubCLI: @escaping () -> Bool = { GitHubTokenProvider().token() != nil },
                     reloadGitHubToken: @escaping @Sendable () -> String? = { GitHubTokenProvider().token() },
                     vercelCLISession: VercelCLISession = .shared,
                     now: @escaping () -> Date = Date.init) {
        self.init(defaults: defaults, credentials: credentials, strategies: [
            VercelCLICredential(detect: detectCLI, reload: reloadCLIToken, session: vercelCLISession),
            GitHubCLICredential(detect: detectGitHubCLI, reload: reloadGitHubToken, now: now),
            KeychainCredential(store: credentials),
        ])
    }

    init(defaults: UserDefaults, credentials: CredentialStore, strategies: [CredentialStrategy]) {
        self.defaults = defaults
        self.credentials = credentials
        self.strategies = strategies
        let savedAccounts = Self.load(defaults)
        self.accounts = savedAccounts
        self.hadPersistedAccounts = !savedAccounts.isEmpty

        for strategy in strategies where !accounts.contains(where: { strategy.handles($0.source) }) {
            guard let detected = strategy.detectAccount() else { continue }
            switch detected.placement {
            case .first: accounts.insert(detected.account, at: 0)
            case .last:  accounts.append(detected.account)
            }
            persist()
        }
    }

    /// The detected Vercel CLI account, if present.
    var cliAccount: Account? { accounts.first { $0.source == .vercelCLI } }
    /// The detected GitHub CLI (`gh`) account, if present.
    var githubCLIAccount: Account? { accounts.first { $0.source == .githubCLI } }

    func strategy(for account: Account) -> CredentialStrategy? {
        strategies.first { $0.handles(account.source) }
    }

    func resolve(_ account: Account) -> ResolvedCredential? {
        strategy(for: account)?.resolve(account)
    }

    func token(for account: Account) -> String? {
        resolve(account)?.token
    }

    func recoverFromUnauthorized(_ account: Account, rejectedToken: String) -> AuthRecovery {
        strategy(for: account)?.recoverFromUnauthorized(account, rejectedToken: rejectedToken) ?? .retryAfterBackoff
    }

    /// Test hook: the in-flight background `gh` re-read.
    var gitHubCLITokenRefresh: Task<Void, Never>? {
        strategies.lazy.compactMap { $0 as? GitHubCLICredential }.first?.refresh
    }

    static let gitHubCLITokenFreshness = GitHubCLICredential.freshness

    @discardableResult
    func addKeychainAccount(provider: Provider, label: String, token: String,
                            organization: String? = nil) -> Account {
        let kcName = "acct-\(UUID().uuidString)"
        credentials.setToken(token, for: kcName)
        let acct = Account(id: UUID(), provider: provider, label: label,
                           source: .keychain(account: kcName), organization: organization)
        accounts.append(acct)
        persist()
        return acct
    }

    /// Inserts a pre-built account directly. Demo mode only: CLI-backed accounts
    /// are auto-detected in production, so there is no other way to seed one.
    func adoptDemoAccount(_ account: Account) {
        accounts.append(account)
        persist()
    }

    /// Labels are local metadata, including for automatically detected CLI accounts.
    func renameAccount(_ account: Account, label: String) {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[index].label != name else { return }
        accounts[index].label = name
        persist()
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
