import Foundation

/// The Vercel CLI's own login (`vercel login`), read from disk and renewed by
/// `VercelCLISession`. The CLI rotates the token, so a 401 is often just a
/// token we read before the rotation.
@MainActor
final class VercelCLICredential: CredentialStrategy {
    private let detect: () -> Bool
    private let reload: () -> String?
    private let session: VercelCLISession

    init(detect: @escaping () -> Bool = { (try? TokenProvider().credentials()) != nil },
         reload: @escaping () -> String? = { try? TokenProvider().credentials().token },
         session: VercelCLISession = .shared) {
        self.detect = detect
        self.reload = reload
        self.session = session
    }

    var detectedProvider: Provider? { .vercel }
    var caption: String { String(localized: "From Vercel CLI", comment: "CLI account source caption") }
    var signInHint: LocalizedStringResource? { "Sign in with vercel login, then restart DeployBar." }
    var loggedOutHint: String? {
        String(localized: "Not logged in — run `vercel login`",
               comment: "Health issue: the Vercel CLI has no session")
    }

    func handles(_ source: CredentialSource) -> Bool { source == .vercelCLI }

    /// The renewing CLI session transport, independent of whether a token can
    /// be read from disk right now.
    var transport: HTTPFetch {
        let session = self.session
        return { try await session.data(for: $0) }
    }

    func detectAccount() -> DetectedAccount? {
        guard detect() else { return nil }
        return DetectedAccount(account: .vercelCLI(id: UUID(), label: "Vercel CLI"), placement: .first)
    }

    func resolve(_ account: Account) -> ResolvedCredential? {
        guard let token = reload() else { return nil }
        return ResolvedCredential(token: token, transport: transport)
    }

    /// Compared with the token the failed client held, not the last one handed
    /// out: another scope may already have resolved the rotated token.
    func recoverFromUnauthorized(_ account: Account, rejectedToken: String) -> AuthRecovery {
        guard let fresh = reload(), !fresh.isEmpty, fresh != rejectedToken else { return .retryAfterBackoff }
        return .retryWithFreshClient
    }

    /// Mutes from before follow keys used project ids were stored by name.
    func legacyFollowKey(for account: Account, projectName: String) -> ProjectKey? {
        ProjectKey(provider: .vercel, accountId: account.id, projectId: projectName)
    }
}
