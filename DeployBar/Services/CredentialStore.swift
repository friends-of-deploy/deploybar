import Foundation
import Security
import os

protocol CredentialStore {
    func token(for account: String) -> String?
    func setToken(_ token: String, for account: String)
    func removeToken(for account: String)
}

final class InMemoryCredentialStore: CredentialStore {
    private var storage: [String: String] = [:]
    func token(for account: String) -> String? { storage[account] }
    func setToken(_ token: String, for account: String) { storage[account] = token }
    func removeToken(for account: String) { storage[account] = nil }
}

/// Generic-password Keychain storage. macOS 14 compatible (uses the C Security API).
struct KeychainCredentialStore: CredentialStore {
    let service: String
    init(service: String = "io.eightlines.deploybar") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func token(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    func setToken(_ token: String, for account: String) {
        let data = Data(token.utf8)
        // Try update first; insert if missing.
        let updated = SecItemUpdate(baseQuery(account) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            let added = SecItemAdd(add as CFDictionary, nil)
            if added != errSecSuccess {
                os_log("keychain setToken add failed: %d", added)
            }
        } else if updated != errSecSuccess {
            os_log("keychain setToken update failed: %d", updated)
        }
    }

    func removeToken(for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
