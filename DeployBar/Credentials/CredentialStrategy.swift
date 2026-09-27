import Foundation

/// What a 401 means for a credential source, and so how the one retry goes.
enum AuthRecovery: Equatable, Sendable {
    /// The source has a newer token than the client was built with: rebuild, retry at once.
    case retryWithFreshClient
    /// Nothing new to try: wait out a transient blip, then retry the same client.
    case retryAfterBackoff
}

/// An account found on this Mac rather than added in Settings.
struct DetectedAccount {
    enum Placement: Equatable { case first, last }
    let account: Account
    /// The Vercel CLI account has always led the list; `gh` joins at the end.
    let placement: Placement
}

/// Where one kind of account gets its token and how that token renews. One
/// conformance per `CredentialSource` case, owned by `AccountStore`.
@MainActor
protocol CredentialStrategy: AnyObject {
    /// The provider this source signs into on the Mac; nil when it detects nothing.
    var detectedProvider: Provider? { get }
    /// Shown under the account in Settings.
    var caption: String { get }
    /// Onboarding hint for `detectedProvider` when no login was found.
    var signInHint: LocalizedStringResource? { get }
    /// Health message when every scope has failed auth and this source can say why.
    var loggedOutHint: String? { get }

    func handles(_ source: CredentialSource) -> Bool
    /// The account to add when this source's login is present.
    func detectAccount() -> DetectedAccount?
    func resolve(_ account: Account) -> ResolvedCredential?
    /// `rejectedToken` is the token the failed client was built with.
    func recoverFromUnauthorized(_ account: Account, rejectedToken: String) -> AuthRecovery
    /// A follow key stored by project name before keys used ids, still honoured.
    func legacyFollowKey(for account: Account, projectName: String) -> ProjectKey?
}

extension CredentialStrategy {
    var detectedProvider: Provider? { nil }
    var signInHint: LocalizedStringResource? { nil }
    var loggedOutHint: String? { nil }
    func detectAccount() -> DetectedAccount? { nil }
    func recoverFromUnauthorized(_ account: Account, rejectedToken: String) -> AuthRecovery { .retryAfterBackoff }
    func legacyFollowKey(for account: Account, projectName: String) -> ProjectKey? { nil }
}
