import Foundation
import Observation

@Observable
@MainActor
final class AccountStore {
    private(set) var accounts: [Account] = []
    let hadPersistedAccounts: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let reloadCLIToken: () -> String?
    @ObservationIgnored private let reloadGitHubToken: @Sendable () -> String?
    @ObservationIgnored private let vercelCLISession: VercelCLISession
    @ObservationIgnored private let now: () -> Date

    /// The last `gh auth token` result and when it was read. `nil` read time
    /// means `gh` has not been asked yet this launch.
    @ObservationIgnored private var gitHubCLIToken: String?
    @ObservationIgnored private var gitHubCLITokenReadAt: Date?
    /// The in-flight background re-read, so stale callers share one `gh` run.
    @ObservationIgnored private(set) var gitHubCLITokenRefresh: Task<Void, Never>?

    /// How long a `gh` token is served before it is re-read in the background.
    /// Long enough that a poll tick reuses one read across all its scopes;
    /// short enough that `gh auth refresh` or a new login is picked up soon.
    static let gitHubCLITokenFreshness: TimeInterval = 60

    private enum Keys { static let accounts = "connectedAccounts" }

    init(defaults: UserDefaults = .standard,
         credentials: CredentialStore = KeychainCredentialStore(),
         detectCLI: () -> Bool = { (try? TokenProvider().credentials()) != nil },
         reloadCLIToken: @escaping () -> String? = { try? TokenProvider().credentials().token },
         detectGitHubCLI: () -> Bool = { GitHubTokenProvider().token() != nil },
         reloadGitHubToken: @escaping @Sendable () -> String? = { GitHubTokenProvider().token() },
         vercelCLISession: VercelCLISession = .shared,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.credentials = credentials
        self.reloadCLIToken = reloadCLIToken
        self.reloadGitHubToken = reloadGitHubToken
        self.vercelCLISession = vercelCLISession
        self.now = now
        let savedAccounts = Self.load(defaults)
        self.accounts = savedAccounts
        self.hadPersistedAccounts = !savedAccounts.isEmpty

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
        case .githubCLI:            return cachedGitHubCLIToken()
        case .keychain(let name):   return credentials.token(for: name)
        }
    }

    /// `gh auth token` spawns a process and waits for it. This store is on the
    /// main actor and the poll builds a client per scope, so reading it on
    /// every call froze the popover — scrolling and buttons included — for as
    /// long as a tick's worth of `gh` runs took. Only the first read of a
    /// launch waits; after that a stale token is served while one background
    /// re-read replaces it.
    private func cachedGitHubCLIToken() -> String? {
        guard let readAt = gitHubCLITokenReadAt else {
            gitHubCLIToken = reloadGitHubToken()
            gitHubCLITokenReadAt = now()
            return gitHubCLIToken
        }
        if now().timeIntervalSince(readAt) >= Self.gitHubCLITokenFreshness,
           gitHubCLITokenRefresh == nil {
            let read = reloadGitHubToken
            gitHubCLITokenRefresh = Task { [weak self] in
                let token = await Task.detached(priority: .utility) { read() }.value
                guard let self else { return }
                self.gitHubCLIToken = token
                self.gitHubCLITokenReadAt = self.now()
                self.gitHubCLITokenRefresh = nil
            }
        }
        return gitHubCLIToken
    }

    /// Only CLI accounts share the renewable CLI session. Explicit API tokens
    /// must keep using the credentials selected for that account.
    func vercelFetch(for account: Account) -> VercelClient.Fetch {
        guard account.source == .vercelCLI else {
            return { try await URLSession.shared.data(for: $0) }
        }
        let session = vercelCLISession
        return { try await session.data(for: $0) }
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
