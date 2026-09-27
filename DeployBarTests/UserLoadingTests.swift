import XCTest
@testable import DeployBar

@MainActor
final class UserLoadingTests: XCTestCase {

    private func makeStore(serving body: Data) -> (DeploymentStore, AccountStore, Account) {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            credentials: InMemoryCredentialStore(), detectCLI: { false }, detectGitHubCLI: { false })
        let vercel = accounts.addKeychainAccount(provider: .vercel, label: "Vercel", token: "t")
        let store = DeploymentStore(accountStore: accounts,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { _, _ in nil },
            organizationFetch: { req in
                (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        let (store, accounts, vercel) = makeStore(serving: user)
        accounts.removeAccount(vercel)
        await store.loadIdentity(for: vercel)
        XCTAssertNil(store.identity(for: vercel))
    }
}
