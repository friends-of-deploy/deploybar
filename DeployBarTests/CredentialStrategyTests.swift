import XCTest
@testable import DeployBar

@MainActor
final class CredentialStrategyTests: XCTestCase {

    private final class Disk { var token: String?; init(_ t: String?) { token = t } }

    private let cliAccount = Account.vercelCLI(id: UUID(), label: "Vercel CLI")

    private func vercel(_ disk: Disk, detect: Bool = true) -> VercelCLICredential {
        VercelCLICredential(detect: { detect }, reload: { disk.token })
    }

    // MARK: Vercel CLI

    func test_vercelCLIResolvesTheTokenOnDisk() {
        let strategy = vercel(Disk("tok"))
        XCTAssertEqual(strategy.resolve(cliAccount)?.token, "tok")
        XCTAssertNil(vercel(Disk(nil)).resolve(cliAccount))
    }

    func test_vercelCLIRebuildsOnlyAfterTheCLIRotated() {
        let disk = Disk("stale")
        let strategy = vercel(disk)
        _ = strategy.resolve(cliAccount)
        XCTAssertEqual(strategy.recoverFromUnauthorized(cliAccount), .retryAfterBackoff, "nothing new on disk")
        disk.token = "fresh"
        XCTAssertEqual(strategy.recoverFromUnauthorized(cliAccount), .retryWithFreshClient)
        _ = strategy.resolve(cliAccount)
        XCTAssertEqual(strategy.recoverFromUnauthorized(cliAccount), .retryAfterBackoff,
                       "the fresh token is now the one clients hold")
        disk.token = ""
        XCTAssertEqual(strategy.recoverFromUnauthorized(cliAccount), .retryAfterBackoff, "an empty file is no rotation")
    }

    func test_vercelCLIDetectsItselfFirstInTheList() throws {
        let detected = try XCTUnwrap(vercel(Disk("t")).detectAccount())
        XCTAssertEqual(detected.account.source, .vercelCLI)
        XCTAssertEqual(detected.account.provider, .vercel)
        XCTAssertEqual(detected.placement, .first)
        XCTAssertNil(vercel(Disk("t"), detect: false).detectAccount())
    }

    func test_vercelCLIHonoursNameKeyedFollows() {
        XCTAssertEqual(vercel(Disk("t")).legacyFollowKey(for: cliAccount, projectName: "web"),
                       ProjectKey(provider: .vercel, accountId: cliAccount.id, projectId: "web"))
    }

    func test_vercelCLIExplainsALogout() {
        XCTAssertEqual(vercel(Disk("t")).loggedOutHint, "Not logged in — run `vercel login`")
    }

    // MARK: GitHub CLI

    func test_gitHubCLIDetectsItselfLastInTheList() throws {
        let strategy = GitHubCLICredential(detect: { true }, reload: { "gho" })
        let detected = try XCTUnwrap(strategy.detectAccount())
        XCTAssertEqual(detected.account.source, .githubCLI)
        XCTAssertEqual(detected.placement, .last)
        XCTAssertEqual(strategy.resolve(detected.account)?.token, "gho")
        XCTAssertEqual(strategy.recoverFromUnauthorized(detected.account), .retryAfterBackoff)
    }

    // MARK: Keychain

    func test_keychainResolvesItsOwnItemOnly() {
        let store = InMemoryCredentialStore()
        store.setToken("secret", for: "acct-1")
        let strategy = KeychainCredential(store: store)
        let account = Account(id: UUID(), provider: .github, label: "G", source: .keychain(account: "acct-1"))
        XCTAssertEqual(strategy.resolve(account)?.token, "secret")
        XCTAssertNil(strategy.resolve(Account(id: UUID(), provider: .github, label: "G",
                                              source: .keychain(account: "missing"))))
        XCTAssertTrue(strategy.handles(.keychain(account: "anything")))
        XCTAssertFalse(strategy.handles(.vercelCLI))
        XCTAssertNil(strategy.detectAccount())
        XCTAssertNil(strategy.legacyFollowKey(for: account, projectName: "web"))
    }

    // MARK: Store

    func test_everySourceHasItsOwnCaption() {
        let store = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                 credentials: InMemoryCredentialStore(),
                                 detectCLI: { false }, detectGitHubCLI: { false })
        let captions = [CredentialSource.vercelCLI, .githubCLI, .keychain(account: "k")].map { source in
            store.strategies.first { $0.handles(source) }!.caption
        }
        XCTAssertEqual(captions, ["From Vercel CLI", "From GitHub CLI", "Token"])
    }

    /// A transient nil read from `reloadCLIToken` must not silently drop a CLI
    /// account to plain `URLSession`: `vercelFetch(for:)` has to keep routing by
    /// the account's source, not by whether a token could be read just now.
    /// Before the fix this asserted "Bearer cli-token" but got no Authorization
    /// header at all, because `resolve(account)?.transport` was nil and the
    /// shim fell back to `URLSession.shared`.
    func test_vercelFetchKeepsTheCLISessionEvenWhenTheTokenReadFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try #"{"token":"cli-token"}"#.write(to: dir.appendingPathComponent("auth.json"),
                                            atomically: true, encoding: .utf8)

        actor Seen { var authorization: String?; func record(_ v: String?) { authorization = v } }
        let seen = Seen()
        let session = VercelCLISession(provider: TokenProvider(configDirectory: dir)) { request in
            await seen.record(request.value(forHTTPHeaderField: "Authorization"))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let store = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                 credentials: InMemoryCredentialStore(),
                                 detectCLI: { true }, reloadCLIToken: { nil },
                                 detectGitHubCLI: { false }, vercelCLISession: session)
        let cli = try XCTUnwrap(store.cliAccount)
        _ = try await store.vercelFetch(for: cli)(URLRequest(url: URL(string: "https://api.vercel.com/v2/user")!))
        let authorization = await seen.authorization
        XCTAssertEqual(authorization, "Bearer cli-token")
    }

    /// A keychain account must never be routed through the Vercel CLI session.
    func test_vercelFetchDoesNotRouteKeychainAccountsThroughTheCLISession() {
        let store = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                 credentials: InMemoryCredentialStore(),
                                 detectCLI: { false }, detectGitHubCLI: { false })
        let acct = store.addKeychainAccount(provider: .vercel, label: "bob", token: "tok")
        XCTAssertFalse(store.strategy(for: acct) is VercelCLICredential)
    }
}
