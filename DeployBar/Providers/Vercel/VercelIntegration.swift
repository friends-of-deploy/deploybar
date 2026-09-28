import Foundation

/// Vercel: projects and deployments per personal account and per team.
struct VercelIntegration: ProviderIntegration {
    let provider = Provider.vercel

    /// Vercel rate-limits per endpoint per minute, far more generously than an
    /// hourly figure implies — 20000/h is a safety rail against pathological
    /// scope counts, not a mirror of a documented quota. A scope costs two
    /// requests: deployments and projects.
    let pollCost = PollCostModel(
        hourlyLimit: 20000,
        maxRequestsPerScope: 2,
        estimatedCost: { _, _ in 2 },
        sharedReserve: { _ in 0 },
        metersOffCyclePolls: false,
        reservesInProgressRefreshes: false)

    let presentation = ProviderPresentation(
        vocabulary: .deployments,
        tokenCreationURL: URL(string: "https://vercel.com/account/settings/tokens")!,
        tokenHint: "Use a Vercel token with access to the projects you want to follow.",
        projectMenuLinks: { project, scope in
            var links: [ProjectLink] = []
            if let env = LinkBuilder.projectEnv(scope: scope, project: project.name) {
                links.append(ProjectLink(title: "Environment variables", systemImage: "key.fill", url: env))
            }
            if project.hasAnalytics,
               let analytics = LinkBuilder.projectAnalytics(scope: scope, project: project.name) {
                links.append(ProjectLink(title: "Analytics", systemImage: "chart.bar.xaxis", url: analytics))
            }
            if let settings = LinkBuilder.projectSettings(scope: scope, project: project.name) {
                links.append(ProjectLink(title: "Project settings", systemImage: "gearshape", url: settings))
            }
            if let dashboard = LinkBuilder.projectDashboard(scope: scope, project: project.name) {
                links.append(ProjectLink(title: "Vercel dashboard", systemImage: "square.grid.2x2", url: dashboard))
            }
            return links
        },
        // Vercel scopes personal projects under the username, not the account label.
        ownerLabel: { $0?.username })

    func identity(for account: Account, using credential: ResolvedCredential) async throws -> AccountIdentity {
        let user = try await UserClient(token: credential.token, fetch: credential.transport).user()
        return AccountIdentity(username: user.username)
    }

    func organizations(for account: Account, using credential: ResolvedCredential) async throws -> [Team] {
        try await TeamsClient(token: credential.token, fetch: credential.transport).teams()
    }

    @MainActor
    func client(for scope: Scope, using credential: ResolvedCredential) -> DeploymentProviderClient? {
        VercelClient(credentials: VercelCredentials(token: credential.token, teamId: scope.teamId),
                     fetch: credential.transport)
    }

    func failureReport(for deployment: Deployment, teamId: String?,
                       using credential: ResolvedCredential) async throws -> String {
        let client = VercelClient(credentials: VercelCredentials(token: credential.token, teamId: teamId),
                                  fetch: credential.transport)
        return BuildErrorReport.make(for: deployment, events: try await client.buildEvents(deploymentId: deployment.uid))
    }
}
