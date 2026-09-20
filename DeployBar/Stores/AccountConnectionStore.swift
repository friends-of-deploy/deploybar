import Foundation
import Observation

/// Verifies credentials before persisting them. The injectable validator keeps
/// failures, cancellation and Keychain rollback testable without real accounts.
@MainActor
@Observable
final class AccountConnectionStore {
    typealias Validate = (Provider, String) async throws -> String

    var provider: Provider = .vercel { didSet { errorMessage = nil } }
    var token = ""
    private(set) var isConnecting = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let validate: Validate

    init(validate: @escaping Validate = AccountConnectionStore.validateToken) {
        self.validate = validate
    }

    var canConnect: Bool { !isConnecting && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func connect(to accounts: AccountStore, label: String = "") async -> Account? {
        guard canConnect else { return nil }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        let selectedProvider = provider
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let name = try await validate(selectedProvider, credential)
            try Task.checkCancellation()
            let customLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = accounts.addKeychainAccount(provider: selectedProvider,
                                                      label: customLabel.isEmpty ? name : customLabel,
                                                      token: credential)
            guard accounts.token(for: account) == credential else {
                accounts.removeAccount(account)
                errorMessage = String(localized: "Your token couldn’t be saved in Keychain. Unlock your Mac and try again.")
                return nil
            }
            token = ""
            return account
        } catch is CancellationError {
            return nil
        } catch {
            // Never surface raw network diagnostics that might contain credentials.
            errorMessage = String(localized: "Couldn’t connect. Check your token, its permissions, and your internet connection, then try again.")
            return nil
        }
    }

    private static func validateToken(provider: Provider, token: String) async throws -> String {
        switch provider {
        case .vercel: return try await UserClient(token: token).user().username
        case .github: return try await GitHubClient(token: token).authenticatedLogin()
        case .azureDevOps: throw URLError(.unsupportedURL)
        }
    }
}
