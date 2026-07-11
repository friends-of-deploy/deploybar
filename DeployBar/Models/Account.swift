import Foundation

enum CredentialSource: Codable, Equatable, Sendable {
    case vercelCLI
    case githubCLI
    case keychain(account: String)
}

struct Account: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let provider: Provider
    var label: String
    let source: CredentialSource

    /// CLI-backed accounts are auto-detected and can't be removed in the UI.
    var isReadOnly: Bool {
        switch source {
        case .vercelCLI, .githubCLI: return true
        case .keychain:              return false
        }
    }

    static func vercelCLI(id: UUID, label: String) -> Account {
        Account(id: id, provider: .vercel, label: label, source: .vercelCLI)
    }

    static func githubCLI(id: UUID, label: String) -> Account {
        Account(id: id, provider: .github, label: label, source: .githubCLI)
    }
}
