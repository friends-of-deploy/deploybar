import XCTest
@testable import VercelBar

@MainActor
final class AccountStoreTests: XCTestCase {
    private func fresh(detectCLI: Bool = false) -> (AccountStore, InMemoryCredentialStore, UserDefaults) {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let creds = InMemoryCredentialStore()
        let store = AccountStore(defaults: d, credentials: creds, detectCLI: { detectCLI })
        return (store, creds, d)
    }

    func test_noCLI_startsEmpty() {
        let (store, _, _) = fresh(detectCLI: false)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.cliAccount)
    }

    func test_cliDetected_createsReadOnlyAccount() {
        let (store, _, _) = fresh(detectCLI: true)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.cliAccount?.source, .vercelCLI)
        XCTAssertTrue(store.cliAccount!.isReadOnly)
    }

    func test_cliAccount_idStableAcrossInstances() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let s1 = AccountStore(defaults: d, credentials: InMemoryCredentialStore(), detectCLI: { true })
        let firstId = s1.cliAccount!.id
        let s2 = AccountStore(defaults: d, credentials: InMemoryCredentialStore(), detectCLI: { true })
        XCTAssertEqual(s2.cliAccount!.id, firstId)
    }

    func test_addKeychainAccount_storesTokenAndPersists() {
        let (store, creds, d) = fresh()
        let acct = store.addKeychainAccount(provider: .vercel, label: "bob", token: "tok-9")
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.token(for: acct), "tok-9")
        // Persisted across a reload:
        let reloaded = AccountStore(defaults: d, credentials: creds, detectCLI: { false })
        XCTAssertEqual(reloaded.accounts.count, 1)
        XCTAssertEqual(reloaded.token(for: reloaded.accounts[0]), "tok-9")
    }

    func test_removeAccount_deletesSecret() {
        let (store, creds, _) = fresh()
        let acct = store.addKeychainAccount(provider: .vercel, label: "bob", token: "tok-9")
        store.removeAccount(acct)
        XCTAssertTrue(store.accounts.isEmpty)
        if case .keychain(let name) = acct.source { XCTAssertNil(creds.token(for: name)) }
    }
}
