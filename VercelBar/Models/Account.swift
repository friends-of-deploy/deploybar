import Foundation

enum CredentialSource: Codable, Equatable, Sendable {
    case vercelCLI
    case keychain(account: String)
}

struct Account: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let provider: Provider
    var label: String
    let source: CredentialSource

    var isReadOnly: Bool { source == .vercelCLI }

    static func vercelCLI(id: UUID, label: String) -> Account {
        Account(id: id, provider: .vercel, label: label, source: .vercelCLI)
    }
}
