import Foundation

/// The transport every client takes: `URLSession`, or the Vercel CLI session
/// that renews its own token.
typealias HTTPFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// A token ready to use, plus the transport that has to carry it. Integrations
/// build clients from this and never learn which credential source it came from.
struct ResolvedCredential: Sendable {
    let token: String
    let transport: HTTPFetch

    static func plain(_ token: String) -> ResolvedCredential {
        ResolvedCredential(token: token, transport: { try await URLSession.shared.data(for: $0) })
    }
}

/// Who an account is signed in as.
struct AccountIdentity: Equatable, Sendable {
    let username: String
}

/// Everything DeployBar knows about one provider's API. One conformance per
/// provider, registered in `ProviderRegistry`; stores and views ask this
/// instead of switching on `Provider`.
protocol ProviderIntegration: Sendable {
    var provider: Provider { get }
    /// Whether an account polls a scope of its own besides its organizations.
    var hasAccountScope: Bool { get }
    var pollCost: PollCostModel { get }
    var presentation: ProviderPresentation { get }

    /// Validates the credential and names the account.
    func identity(using credential: ResolvedCredential) async throws -> AccountIdentity
    /// Teams / organizations the account can see, each polled as its own scope.
    func organizations(for account: Account, using credential: ResolvedCredential) async throws -> [Team]
    /// A client for one scope, or nil when there is nothing to poll there.
    @MainActor func client(for scope: Scope, using credential: ResolvedCredential) -> DeploymentProviderClient?
    /// A paste-ready report for a failed deployment or run.
    func failureReport(for deployment: Deployment, teamId: String?,
                       using credential: ResolvedCredential) async throws -> String
    /// Called once at the start of every poll tick.
    func beginTick() async
}

extension ProviderIntegration {
    var hasAccountScope: Bool { true }
    func beginTick() async {}
}
