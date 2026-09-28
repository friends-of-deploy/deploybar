import XCTest
@testable import DeployBar

@MainActor
final class ProviderWiringTests: XCTestCase {

    private final class Disk: @unchecked Sendable {
        var token: String
        init(_ token: String) { self.token = token }
    }

    private final class Recorder: @unchecked Sendable {
        var clientsBuilt = 0
    }

    /// Rejects everything but "fresh"; a rejection makes the CLI rotate on disk.
    private struct RotatingClient: DeploymentProviderClient {
        let token: String
        let key: String
        let disk: Disk
        func deployments(limit: Int) async throws -> [Deployment] {
            guard token == "fresh" else {
                disk.token = "fresh"
                throw ProviderClientError.unauthorized
            }
            return [Deployment(uid: "d_\(key)", name: "web", stateRaw: "READY", url: "web.vercel.app", createdAt: 1)]
        }
        func projects() async throws -> [Project] { [] }
    }

    /// Review focus 1. Scopes that built a client with the old token in the
    /// same tick may each take one retry with it; none may reach the logout
    /// threshold, and all recover by the next tick.
    func test_rotationDuringAMultiTeamTickRecoversEveryScope() async {
        let disk = Disk("stale")
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { true }, reloadCLIToken: { disk.token },
                                    detectGitHubCLI: { false })
        let store = DeploymentStore(
            accountStore: accounts,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { account, teamId in
                RotatingClient(token: accounts.token(for: account) ?? "", key: teamId ?? "personal", disk: disk)
            },
            authRetryBackoff: .zero)
        store.setOrganizations([Team(id: "t1", slug: "t1", name: "t1"),
                                Team(id: "t2", slug: "t2", name: "t2")], for: accounts.cliAccount!.id)

        await store.poll()
        await store.poll()

        XCTAssertEqual(Set(store.deployments.map(\.uid)), ["d_personal", "d_t1", "d_t2"])
        XCTAssertTrue(store.healthIssues.isEmpty, "\(store.healthIssues)")
        XCTAssertNotEqual(store.iconState, .loggedOut)
    }

    /// Rejects everything but "fresh". On rejection the CLI rotates on disk and
    /// something else resolves the rotated token before the 401 is handled.
    private struct InterleavedClient: DeploymentProviderClient {
        let token: String
        let disk: Disk
        let recorder: Recorder
        let resolveElsewhere: @Sendable () async -> Void
        func deployments(limit: Int) async throws -> [Deployment] {
            guard token == "fresh" else {
                disk.token = "fresh"
                await resolveElsewhere()
                throw ProviderClientError.unauthorized
            }
            return [Deployment(uid: "d_personal", name: "web", stateRaw: "READY", url: "web.vercel.app", createdAt: 1)]
        }
        func projects() async throws -> [Project] { [] }
    }

    /// A scope whose client was built with the old token gets a fresh client at
    /// once, even when another scope (or an identity load) resolved the rotated
    /// token between that build and the 401.
    func test_rotationSeenByAnotherResolveStillRebuildsTheRejectedClient() async {
        let disk = Disk("stale")
        let recorder = Recorder()
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { true }, reloadCLIToken: { disk.token },
                                    detectGitHubCLI: { false })
        let cli = accounts.cliAccount!
        let store = DeploymentStore(
            accountStore: accounts,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { account, _ in
                recorder.clientsBuilt += 1
                return InterleavedClient(token: accounts.token(for: account) ?? "", disk: disk, recorder: recorder,
                                         resolveElsewhere: { await MainActor.run { _ = accounts.resolve(cli) } })
            },
            authRetryBackoff: .zero)

        await store.poll()

        XCTAssertEqual(store.deployments.map(\.uid), ["d_personal"], "recovers within the same poll")
        XCTAssertEqual(recorder.clientsBuilt, 2, "the rejected client is rebuilt, not retried")
    }

    /// Review focus 2.
    func test_accountWithoutACredentialIsSkippedSilently() async {
        let credentials = InMemoryCredentialStore()
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: credentials, detectCLI: { false }, detectGitHubCLI: { false })
        let account = accounts.addKeychainAccount(provider: .github, label: "G", token: "t")
        if case .keychain(let name) = account.source { credentials.removeToken(for: name) }
        let recorder = Recorder()
        let store = DeploymentStore(
            accountStore: accounts,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { _, _ in recorder.clientsBuilt += 1; return nil },
            authRetryBackoff: .zero)

        for _ in 0..<4 { await store.poll() }

        XCTAssertEqual(recorder.clientsBuilt, 0, "no credential, no client")
        XCTAssertTrue(store.healthIssues.isEmpty)
        XCTAssertNotEqual(store.iconState, .loggedOut)
    }

    /// Review focus 3: the default validator has nothing to ask for Azure DevOps.
    func test_providerWithoutIntegrationCannotBeConnected() async {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { false }, detectGitHubCLI: { false })
        let connection = AccountConnectionStore(registry: ProviderRegistry([VercelIntegration(), GitHubIntegration()]))
        connection.provider = .azureDevOps
        connection.token = "pat"

        let account = await connection.connect(to: accounts)

        XCTAssertNil(account)
        XCTAssertNotNil(connection.errorMessage)
        XCTAssertTrue(accounts.accounts.isEmpty)
    }
}
