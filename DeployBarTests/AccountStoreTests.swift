import XCTest
@testable import DeployBar

@MainActor
final class AccountStoreTests: XCTestCase {
    private func fresh(detectCLI: Bool = false) -> (AccountStore, InMemoryCredentialStore, UserDefaults) {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let creds = InMemoryCredentialStore()
        let store = AccountStore(defaults: d, credentials: creds, detectCLI: { detectCLI },
                                 detectGitHubCLI: { false })
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
        let s1 = AccountStore(defaults: d, credentials: InMemoryCredentialStore(), detectCLI: { true },
                              detectGitHubCLI: { false })
        let firstId = s1.cliAccount!.id
        let s2 = AccountStore(defaults: d, credentials: InMemoryCredentialStore(), detectCLI: { true },
                              detectGitHubCLI: { false })
        XCTAssertEqual(s2.cliAccount!.id, firstId)
    }

    func test_addKeychainAccount_storesTokenAndPersists() {
        let (store, creds, d) = fresh()
        let acct = store.addKeychainAccount(provider: .vercel, label: "bob", token: "tok-9")
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.token(for: acct), "tok-9")
        // Persisted across a reload:
        let reloaded = AccountStore(defaults: d, credentials: creds, detectCLI: { false },
                                    detectGitHubCLI: { false })
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

    // MARK: - GitHub CLI (`gh`) reuse

    private func store(detectGH: Bool, ghToken: String? = "gho_test",
                       defaults: UserDefaults? = nil) -> AccountStore {
        AccountStore(defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!,
                     credentials: InMemoryCredentialStore(),
                     detectCLI: { false },
                     reloadCLIToken: { nil },
                     detectGitHubCLI: { detectGH },
                     reloadGitHubToken: { ghToken })
    }

    func test_githubCLIDetected_createsReadOnlyGitHubAccount() {
        let s = store(detectGH: true)
        XCTAssertEqual(s.accounts.count, 1)
        let gh = s.githubCLIAccount
        XCTAssertEqual(gh?.source, .githubCLI)
        XCTAssertEqual(gh?.provider, .github)
        XCTAssertTrue(gh!.isReadOnly)
        XCTAssertNil(s.cliAccount)                 // distinct from the Vercel CLI account
    }

    func test_githubCLINotDetected_startsEmpty() {
        XCTAssertNil(store(detectGH: false).githubCLIAccount)
    }

    func test_githubCLIToken_readViaReloadClosure() {
        let s = store(detectGH: true, ghToken: "gho_live")
        XCTAssertEqual(s.token(for: s.githubCLIAccount!), "gho_live")
    }

    func test_githubCLIAccount_idStableAcrossInstances() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let first = store(detectGH: true, defaults: d).githubCLIAccount!.id
        let second = store(detectGH: true, defaults: d).githubCLIAccount!.id
        XCTAssertEqual(second, first)
    }

    func test_cliAndGitHubCLICoexist() {
        let s = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                             credentials: InMemoryCredentialStore(),
                             detectCLI: { true },
                             reloadCLIToken: { "vercel-tok" },
                             detectGitHubCLI: { true },
                             reloadGitHubToken: { "gho_tok" })
        XCTAssertEqual(s.accounts.count, 2)
        XCTAssertNotNil(s.cliAccount)
        XCTAssertNotNil(s.githubCLIAccount)
    }
}
