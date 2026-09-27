import Foundation
@testable import DeployBar

/// Builds a per-scope client for an account and team: how tests stand in for a provider's API.
typealias ClientFactory = @MainActor (Account, _ teamId: String?) -> DeploymentProviderClient?

/// A real integration with parts swapped for test doubles. Everything not
/// overridden (budget, presentation, failure reports) is the real provider's,
/// so budget tests keep exercising production numbers.
struct OverridingIntegration: ProviderIntegration, @unchecked Sendable {
    let base: any ProviderIntegration
    let makeClient: ClientFactory?
    /// Transport for identity and organization discovery.
    let discoveryFetch: HTTPFetch?
    /// Transport for the real client, when `makeClient` doesn't replace it.
    let clientFetch: HTTPFetch?

    var provider: Provider { base.provider }
    var hasAccountScope: Bool { base.hasAccountScope }
    var pollCost: PollCostModel { base.pollCost }
    var presentation: ProviderPresentation { base.presentation }

    func identity(using credential: ResolvedCredential) async throws -> AccountIdentity {
        try await base.identity(using: swapped(credential, discoveryFetch))
    }

    func organizations(for account: Account, using credential: ResolvedCredential) async throws -> [Team] {
        try await base.organizations(for: account, using: swapped(credential, discoveryFetch))
    }

    @MainActor
    func client(for scope: Scope, using credential: ResolvedCredential) -> DeploymentProviderClient? {
        if let makeClient { return makeClient(scope.account, scope.teamId) }
        return base.client(for: scope, using: swapped(credential, clientFetch))
    }

    func failureReport(for deployment: Deployment, teamId: String?,
                       using credential: ResolvedCredential) async throws -> String {
        try await base.failureReport(for: deployment, teamId: teamId, using: credential)
    }

    func beginTick() async { await base.beginTick() }

    private func swapped(_ credential: ResolvedCredential, _ fetch: HTTPFetch?) -> ResolvedCredential {
        fetch.map { ResolvedCredential(token: credential.token, transport: $0) } ?? credential
    }
}

extension ProviderRegistry {
    /// `live()` with test doubles swapped in. `gitHubFetch` reaches only GitHub's real client.
    static func testing(makeClient: ClientFactory? = nil,
                        organizationFetch: HTTPFetch? = nil,
                        gitHubFetch: HTTPFetch? = nil) -> ProviderRegistry {
        ProviderRegistry(ProviderRegistry.live().all.map { base in
            OverridingIntegration(base: base, makeClient: makeClient, discoveryFetch: organizationFetch,
                                  clientFetch: base.provider == .github ? gitHubFetch : nil)
        })
    }
}

extension DeploymentStore {
    /// What store tests build: the live registry with doubles swapped in. The
    /// parameters match the production init from before the refactor, so test
    /// call sites did not have to change.
    convenience init(accountStore: AccountStore,
                     settings: SettingsStore,
                     makeClient: ClientFactory? = nil,
                     organizationFetch: HTTPFetch? = nil,
                     gitHubFetch: HTTPFetch? = nil,
                     now: @escaping () -> Date = Date.init,
                     authRetryBackoff: Duration = .milliseconds(800)) {
        self.init(accountStore: accountStore, settings: settings,
                  registry: .testing(makeClient: makeClient, organizationFetch: organizationFetch,
                                     gitHubFetch: gitHubFetch),
                  now: now, authRetryBackoff: authRetryBackoff)
    }
}
