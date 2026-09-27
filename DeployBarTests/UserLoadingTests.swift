import XCTest
@testable import DeployBar

@MainActor
final class UserLoadingTests: XCTestCase {

    /// `removeMidRequest` removes the account while its identity request is in
    /// flight, after its credential was already resolved.
    private func makeStore(serving body: Data,
                           removeMidRequest: Bool = false) -> (DeploymentStore, AccountStore, Account) {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            credentials: InMemoryCredentialStore(), detectCLI: { false }, detectGitHubCLI: { false })
        let vercel = accounts.addKeychainAccount(provider: .vercel, label: "Vercel", token: "t")
        let store = DeploymentStore(accountStore: accounts,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { _, _ in nil },
            organizationFetch: { req in
                if removeMidRequest { await MainActor.run { accounts.removeAccount(vercel) } }
                return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        return (store, accounts, vercel)
    }

    func test_loadIdentitiesAsksEachAccountWhoItIs() async throws {
        let user = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "user", withExtension: "json")))
        let (store, _, vercel) = makeStore(serving: user)
        await store.loadIdentities()
        XCTAssertFalse(try XCTUnwrap(store.identity(for: vercel)).username.isEmpty)
    }

    /// Behaviour change 1: a token-added Vercel account gets an owner label
    /// too; it used to be limited to the CLI account.
    func test_tokenAddedVercelAccountGetsAnOwnerLabel() async throws {
        let user = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "user", withExtension: "json")))
        let (store, _, vercel) = makeStore(serving: user)
        await store.loadIdentities()
        let username = try XCTUnwrap(store.identity(for: vercel)).username
        XCTAssertEqual(store.projectOwnerLabel(accountId: vercel.id, teamId: nil), username)
    }

    /// Identity that lands after the account was removed must not be kept.
    func test_identityForARemovedAccountIsDropped() async throws {
        let user = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "user", withExtension: "json")))
        let (store, accounts, vercel) = makeStore(serving: user, removeMidRequest: true)
        await store.loadIdentity(for: vercel)
        XCTAssertFalse(accounts.accounts.contains { $0.id == vercel.id }, "removed while the request was in flight")
        XCTAssertNil(store.identity(for: vercel))
    }

    /// Removing an account forgets who it was signed in as.
    func test_accountsChangedForgetsARemovedAccountsIdentity() async throws {
        let user = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "user", withExtension: "json")))
        let (store, accounts, vercel) = makeStore(serving: user)
        await store.loadIdentities()
        XCTAssertNotNil(store.identity(for: vercel))
        accounts.removeAccount(vercel)
        await store.accountsChanged()
        XCTAssertNil(store.identity(for: vercel))
    }
}
