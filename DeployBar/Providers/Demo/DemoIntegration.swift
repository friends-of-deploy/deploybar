import Foundation

/// A provider played by scenario data in demo mode. Budget and presentation
/// are the real provider's, so the demo paces and looks like production.
struct DemoIntegration: ProviderIntegration {
    let base: any ProviderIntegration
    let scenario: DemoScenario
    let clock: DemoClock
    /// The scenario account each seeded account was minted from.
    let keyForAccountId: [UUID: String]

    var provider: Provider { base.provider }
    var hasAccountScope: Bool { base.hasAccountScope }
    var pollCost: PollCostModel { base.pollCost }
    var presentation: ProviderPresentation { base.presentation }

    /// Demo accounts have no identity, as before: no owner prefix.
    func identity(for account: Account, using credential: ResolvedCredential) async throws -> AccountIdentity {
        throw URLError(.userAuthenticationRequired)
    }

    /// Demo screenshots have always shown only the Vercel CLI account's teams;
    /// the GitHub fixture's organizations stay hidden.
    func organizations(for account: Account, using credential: ResolvedCredential) async throws -> [Team] {
        guard account.source == .vercelCLI,
              let key = keyForAccountId[account.id],
              let fixture = scenario.accounts.first(where: { $0.key == key }) else { return [] }
        return fixture.teams.map { Team(id: $0.id, slug: $0.slug, name: $0.name) }
    }

    @MainActor
    func client(for scope: Scope, using credential: ResolvedCredential) -> DeploymentProviderClient? {
        guard let key = keyForAccountId[scope.account.id] else { return nil }
        return DemoProviderClient(scenario: scenario, accountKey: key, teamId: scope.teamId, clock: clock)
    }

    func failureReport(for deployment: Deployment, teamId: String?,
                       using credential: ResolvedCredential) async throws -> String {
        throw URLError(.unsupportedURL)
    }
}
