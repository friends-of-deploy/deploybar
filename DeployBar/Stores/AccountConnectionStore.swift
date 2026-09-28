import Foundation
import Observation

/// Verifies credentials before persisting them. The injectable validator keeps
/// failures, cancellation and Keychain rollback testable without real accounts.
@MainActor
@Observable
final class AccountConnectionStore {
    /// Names the account a credential belongs to. `account` is provisional:
    /// provider and, when entered, organization.
    typealias Validate = (Account, String) async throws -> String

    var provider: Provider = .vercel {
        didSet {
            errorMessage = nil
            // An organization typed for one provider must never reach another's validation.
            organization = ""
        }
    }
    var token = ""
    /// Optional organization, for providers that declare `.organization`.
    var organization = ""
    private(set) var isConnecting = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let validate: Validate

    init(registry: ProviderRegistry = .live(), validate: Validate? = nil) {
        self.validate = validate ?? { account, token in
            guard let integration = registry.integration(for: account.provider) else {
                throw URLError(.unsupportedURL)
            }
            return try await integration.identity(for: account, using: .plain(token)).username
        }
    }

    var canConnect: Bool { !isConnecting && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func connect(to accounts: AccountStore, label: String = "") async -> Account? {
        guard canConnect else { return nil }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredOrganization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = Account(id: UUID(), provider: provider, label: "", source: .keychain(account: ""),
                            organization: enteredOrganization.isEmpty ? nil : enteredOrganization)
        do {
            let name = try await validate(draft, credential)
            try Task.checkCancellation()
            let customLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = accounts.addKeychainAccount(provider: draft.provider,
                                                      label: customLabel.isEmpty ? name : customLabel,
                                                      token: credential,
                                                      organization: draft.organization)
            guard accounts.token(for: account) == credential else {
                accounts.removeAccount(account)
                errorMessage = String(localized: "Your token couldn’t be saved in Keychain. Unlock your Mac and try again.")
                return nil
            }
            token = ""
            organization = ""
            return account
        } catch is CancellationError {
            return nil
        } catch AccountValidationError.organizationRequired {
            errorMessage = String(localized: "This token can’t list your organizations. Enter the organization name above.",
                                  comment: "Add account error: the token is limited to one organization")
            return nil
        } catch {
            // Never surface raw network diagnostics that might contain credentials.
            errorMessage = String(localized: "Couldn’t connect. Check your token, its permissions, and your internet connection, then try again.")
            return nil
        }
    }
}
