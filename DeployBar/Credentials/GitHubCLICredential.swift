import Foundation

/// The GitHub CLI's login (`gh auth login`), read by running `gh auth token`.
@MainActor
final class GitHubCLICredential: CredentialStrategy {
    /// How long a `gh` token is served before it is re-read in the background.
    /// Long enough that a poll tick reuses one read across all its scopes;
    /// short enough that `gh auth refresh` or a new login is picked up soon.
    static let freshness: TimeInterval = 60

    private let detect: () -> Bool
    private let reload: @Sendable () -> String?
    private let now: () -> Date
    /// The last `gh auth token` result and when it was read.
    private var token: String?
    private var readAt: Date?
    /// The in-flight background re-read, so stale callers share one `gh` run.
    private(set) var refresh: Task<Void, Never>?

    init(detect: @escaping () -> Bool = { GitHubTokenProvider().token() != nil },
         reload: @escaping @Sendable () -> String? = { GitHubTokenProvider().token() },
         now: @escaping () -> Date = Date.init) {
        self.detect = detect
        self.reload = reload
        self.now = now
    }

    var detectedProvider: Provider? { .github }
    var caption: String { String(localized: "From GitHub CLI", comment: "CLI account source caption") }
    var signInHint: LocalizedStringResource? { "Sign in with gh auth login, then restart DeployBar." }

    func handles(_ source: CredentialSource) -> Bool { source == .githubCLI }

    func detectAccount() -> DetectedAccount? {
        guard detect() else { return nil }
        return DetectedAccount(account: .githubCLI(id: UUID(), label: "GitHub CLI"), placement: .last)
    }

    func resolve(_ account: Account) -> ResolvedCredential? {
        cachedToken().map(ResolvedCredential.plain)
    }

    /// `gh auth token` spawns a process and waits for it. The poll builds a
    /// client per scope on the main actor, so reading it every time froze the
    /// popover. Only the first read of a launch waits; after that a stale token
    /// is served while one background re-read replaces it.
    private func cachedToken() -> String? {
        guard let readAt else {
            token = reload()
            readAt = now()
            return token
        }
        if now().timeIntervalSince(readAt) >= Self.freshness, refresh == nil {
            let read = reload
            refresh = Task { [weak self] in
                let token = await Task.detached(priority: .utility) { read() }.value
                guard let self else { return }
                self.token = token
                self.readAt = self.now()
                self.refresh = nil
            }
        }
        return token
    }
}
