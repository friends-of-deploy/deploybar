import Foundation

struct ProjectKey: Hashable, Codable, Sendable {
    let provider: Provider
    let accountId: UUID
    let projectId: String

    init(provider: Provider, accountId: UUID, projectId: String) {
        self.provider = provider
        self.accountId = accountId
        self.projectId = projectId
    }

    /// Format: "<provider>|<accountUUID>|<projectId>". projectId is last so it
    /// may itself contain no "|" assumption-breaking — Vercel project ids don't.
    var storageString: String {
        "\(provider.rawValue)|\(accountId.uuidString)|\(projectId)"
    }

    init?(storageString: String) {
        let parts = storageString.split(separator: "|", maxSplits: 2,
                                        omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let provider = Provider(rawValue: parts[0]),
              let accountId = UUID(uuidString: parts[1]),
              !parts[2].isEmpty
        else { return nil }
        self.init(provider: provider, accountId: accountId, projectId: parts[2])
    }
}
