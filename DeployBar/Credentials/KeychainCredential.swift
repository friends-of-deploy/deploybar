import Foundation

/// A token pasted into Settings and kept in the Keychain.
@MainActor
final class KeychainCredential: CredentialStrategy {
    private let store: CredentialStore

    init(store: CredentialStore) {
        self.store = store
    }

    var caption: String { String(localized: "Token", comment: "Keychain account source caption") }

    func handles(_ source: CredentialSource) -> Bool {
        if case .keychain = source { return true }
        return false
    }

    func resolve(_ account: Account) -> ResolvedCredential? {
        guard case .keychain(let name) = account.source, let token = store.token(for: name) else { return nil }
        return .plain(token)
    }
}
