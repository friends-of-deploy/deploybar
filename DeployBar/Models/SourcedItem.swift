import Foundation

/// The scope an item was fetched from: an account plus, for Vercel, the team.
/// Carried on the item itself because "All" polls several teams of the SAME
/// account concurrently — the store's `currentTeamId` can't tell them apart.
struct ScopeRef: Hashable, Sendable {
    let accountId: UUID
    let teamId: String?

    var id: String { "\(accountId.uuidString)|\(teamId ?? "personal")" }
}

struct SourcedDeployment: Identifiable {
    let deployment: Deployment
    let account: Account
    /// Vercel team this row came from; nil for personal scope and non-Vercel providers.
    let teamId: String?

    init(deployment: Deployment, account: Account, teamId: String? = nil) {
        self.deployment = deployment
        self.account = account
        self.teamId = teamId
    }

    var scope: ScopeRef { ScopeRef(accountId: account.id, teamId: teamId) }
    var id: String { "\(scope.id)|\(deployment.uid)" }
}

struct SourcedProject: Identifiable {
    let project: Project
    let account: Account
    /// Vercel team this row came from; nil for personal scope and non-Vercel providers.
    let teamId: String?

    init(project: Project, account: Account, teamId: String? = nil) {
        self.project = project
        self.account = account
        self.teamId = teamId
    }

    var scope: ScopeRef { ScopeRef(accountId: account.id, teamId: teamId) }
    var id: String { "\(scope.id)|\(project.id)" }
    var key: ProjectKey {
        ProjectKey(provider: account.provider, accountId: account.id, projectId: project.id)
    }
}

extension Array {
    /// Keeps the first element per key, preserving order. Used to collapse rows
    /// that arrive from more than one polled scope of the same account.
    func deduplicated<K: Hashable>(by key: (Element) -> K) -> [Element] {
        var seen = Set<K>()
        return filter { seen.insert(key($0)).inserted }
    }
}
