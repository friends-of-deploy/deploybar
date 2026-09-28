import Foundation

/// GitHub: repositories as projects, Actions workflow runs as deployments,
/// organizations as scopes.
struct GitHubIntegration: ProviderIntegration {
    let provider = Provider.github
    /// Organization scopes share one repository listing per tick.
    let listing: GitHubRepositoryListing

    init(listing: GitHubRepositoryListing = GitHubRepositoryListing()) {
        self.listing = listing
    }

    /// The authenticated REST limit is 5000/h. An organization reads its
    /// repositories from the shared listing (reserved once per tick), so what
    /// is left is one runs request per repository, up to the fan-out cap. Its
    /// last result says how many repositories that is; with none known, assume
    /// the cap. The account scope lists its own repositories every time.
    let pollCost = PollCostModel(
        hourlyLimit: 5000,
        maxRequestsPerScope: GitHubClient.maxRequestsPerScope,
        estimatedCost: { scope, knownProjects in
            guard scope.teamId != nil else { return GitHubClient.maxRequestsPerScope }
            return knownProjects > 0 ? min(knownProjects, GitHubClient.maxRunRequestsPerScope)
                                     : GitHubClient.maxRunRequestsPerScope
        },
        sharedReserve: { scopes in
            scopes.contains { $0.teamId != nil } ? GitHubClient.maxRepoListingRequests : 0
        },
        metersOffCyclePolls: true,
        reservesInProgressRefreshes: true)

    let presentation = ProviderPresentation(
        vocabulary: .ciRuns,
        tokenCreationURL: URL(string: "https://github.com/settings/personal-access-tokens/new")!,
        tokenHint: "For GitHub, allow read access to your repositories and Actions.",
        projectMenuLinks: { project, _ in
            var links: [ProjectLink] = []
            if let pulls = LinkBuilder.githubPulls(org: project.repoOrg, repo: project.repoName) {
                links.append(ProjectLink(title: "Pull requests", systemImage: "arrow.triangle.merge", url: pulls))
            }
            if let issues = LinkBuilder.githubIssues(org: project.repoOrg, repo: project.repoName) {
                links.append(ProjectLink(title: "Issues", systemImage: "exclamationmark.circle", url: issues))
            }
            if let settings = LinkBuilder.githubRepoSettings(org: project.repoOrg, repo: project.repoName) {
                links.append(ProjectLink(title: "Repository settings", systemImage: "gearshape", url: settings))
            }
            return links
        },
        projectPageURL: { project, _ in LinkBuilder.githubActions(org: project.repoOrg, repo: project.repoName) },
        // Repository names already carry their owner.
        ownerLabel: { _ in nil })

    func identity(for account: Account, using credential: ResolvedCredential) async throws -> AccountIdentity {
        AccountIdentity(username: try await GitHubClient(token: credential.token, fetch: credential.transport)
            .authenticatedLogin())
    }

    func organizations(for account: Account, using credential: ResolvedCredential) async throws -> [Team] {
        try await GitHubOrgsClient(token: credential.token, fetch: credential.transport).organizations()
    }

    @MainActor
    func client(for scope: Scope, using credential: ResolvedCredential) -> DeploymentProviderClient? {
        GitHubClient(token: credential.token, org: scope.teamId, listing: listing, fetch: credential.transport)
    }

    func failureReport(for deployment: Deployment, teamId: String?,
                       using credential: ResolvedCredential) async throws -> String {
        try await GitHubClient(token: credential.token, fetch: credential.transport).failureReport(for: deployment)
    }

    /// A new tick lists repositories afresh, once for every organization.
    func beginTick() async {
        await listing.reset()
    }
}
