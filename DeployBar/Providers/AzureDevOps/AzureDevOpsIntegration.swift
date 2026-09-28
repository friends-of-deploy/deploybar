import Foundation

/// Azure DevOps Services: repositories as projects, pipeline runs as
/// deployments, organizations as the only scopes.
struct AzureDevOpsIntegration: ProviderIntegration {
    let provider = Provider.azureDevOps

    /// An account is nothing but its organizations.
    var hasAccountScope: Bool { false }

    /// ADO throttles by TSTU (≈0.005 per call here, 200 per five minutes), so
    /// 5000/h is only a safety rail. Every organization costs the same worst
    /// case: projects, repositories and up to 20 build lists.
    let pollCost = PollCostModel(
        hourlyLimit: 5000,
        maxRequestsPerScope: AzureDevOpsClient.maxRequestsPerScope,
        estimatedCost: { _, _ in AzureDevOpsClient.maxRequestsPerScope },
        sharedReserve: { _ in 0 },
        metersOffCyclePolls: true,
        reservesInProgressRefreshes: true)

    let presentation = ProviderPresentation(
        vocabulary: .ciRuns,
        tokenCreationURL: URL(string: "https://learn.microsoft.com/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate")!,
        tokenHint: "Allow Build (Read) and Code (Read).",
        projectMenuLinks: { project, organization in
            // Project rows are named "<ADO project>/<repository>".
            let adoProject = project.name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            var links: [ProjectLink] = []
            if let pipelines = AzureDevOpsIntegration.page(organization, adoProject, "_build") {
                links.append(ProjectLink(title: "Pipelines", systemImage: "arrow.triangle.2.circlepath", url: pipelines))
            }
            if let pulls = project.repoURL?.appendingPathComponent("pullrequests") {
                links.append(ProjectLink(title: "Pull requests", systemImage: "arrow.triangle.merge", url: pulls))
            }
            if let settings = AzureDevOpsIntegration.page(organization, adoProject, "_settings/repositories",
                                                          query: [URLQueryItem(name: "repo", value: project.id)]) {
                links.append(ProjectLink(title: "Repository settings", systemImage: "gearshape", url: settings))
            }
            return links
        },
        // Repository names already carry their ADO project.
        ownerLabel: { _ in nil },
        accountFields: [.organization])

    func identity(for account: Account, using credential: ResolvedCredential) async throws -> AccountIdentity {
        if let organization = account.organization {
            let name = try await AzureDevOpsClient(organization: organization, token: credential.token,
                                                   fetch: credential.transport).authenticatedName()
            return AccountIdentity(username: name)
        }
        let name = try await AzureDevOpsOrgsClient(token: credential.token, fetch: credential.transport).displayName()
        return AccountIdentity(username: name)
    }

    func organizations(for account: Account, using credential: ResolvedCredential) async throws -> [Team] {
        if let organization = account.organization {
            return [Team(id: organization, slug: organization, name: organization)]
        }
        return try await AzureDevOpsOrgsClient(token: credential.token, fetch: credential.transport).organizations()
    }

    @MainActor
    func client(for scope: Scope, using credential: ResolvedCredential) -> DeploymentProviderClient? {
        guard let organization = scope.teamId else { return nil }
        return AzureDevOpsClient(organization: organization, token: credential.token, fetch: credential.transport)
    }

    func failureReport(for deployment: Deployment, teamId: String?,
                       using credential: ResolvedCredential) async throws -> String {
        guard let organization = teamId else { throw ProviderClientError.http(-1) }
        return try await AzureDevOpsClient(organization: organization, token: credential.token,
                                           fetch: credential.transport).failureReport(for: deployment)
    }

    /// `https://dev.azure.com/{org}/{project}/{path}`, percent-encoded.
    static func page(_ organization: String, _ project: String, _ path: String,
                     query: [URLQueryItem] = []) -> URL? {
        guard !organization.isEmpty, !project.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dev.azure.com"
        components.path = "/\(organization)/\(project)/\(path)"
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}
