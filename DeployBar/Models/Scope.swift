import Foundation

struct Scope: Identifiable, Equatable, Sendable {
    let account: Account
    let teamId: String?
    let teamName: String?

    var id: String { "\(account.id.uuidString)|\(teamId ?? "personal")" }
    var displayName: String { teamName ?? "personal" }

    /// Account name, qualified by team when the account fans out into several
    /// scopes. Used in health messages, where "reconnect Acme" is ambiguous if
    /// only one of the account's four teams is actually broken.
    var displayLabel: String {
        guard let teamName, !teamName.isEmpty else { return account.label }
        return "\(account.label) / \(teamName)"
    }
}

enum ScopeFilter: Equatable {
    case all
    case provider(Provider)
    case account(UUID)
    case scope(accountId: UUID, teamId: String?)

    func matches(account: Account, teamId: String?) -> Bool {
        switch self {
        case .all:                       return true
        case .provider(let p):           return account.provider == p
        case .account(let id):           return account.id == id
        case .scope(let id, let team):   return account.id == id && team == teamId
        }
    }
}
