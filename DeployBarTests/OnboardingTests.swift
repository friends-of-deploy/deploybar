import XCTest
@testable import DeployBar

@MainActor
final class OnboardingTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "DeployBarTests.Onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func test_newInstallGetsWelcomeButExistingAccountsDoNot() {
        let state = OnboardingState(defaults: defaults)
        XCTAssertTrue(state.shouldPresentAutomatically(hasAccounts: false))
        XCTAssertFalse(state.shouldPresentAutomatically(hasAccounts: true))
    }

    func test_firstCLIDetectionStillGetsWelcomeButNextLaunchDoesNot() {
        let fresh = AccountStore(defaults: defaults, credentials: InMemoryCredentialStore(),
                                 detectCLI: { true }, detectGitHubCLI: { false })
        XCTAssertFalse(fresh.hadPersistedAccounts)
        XCTAssertEqual(fresh.accounts.count, 1)
        XCTAssertTrue(OnboardingState(defaults: defaults).shouldPresentAutomatically(hasAccounts: fresh.hadPersistedAccounts))
        let existing = makeAccounts()
        XCTAssertTrue(existing.hadPersistedAccounts)
        XCTAssertFalse(OnboardingState(defaults: defaults).shouldPresentAutomatically(hasAccounts: existing.hadPersistedAccounts))
    }

    func test_dismissedWelcomeDoesNotReappearOnNextLaunch() {
        let state = OnboardingState(defaults: defaults)
        state.markPresented()
        let relaunched = OnboardingState(defaults: defaults)
        XCTAssertFalse(relaunched.shouldPresentAutomatically(hasAccounts: false))
        XCTAssertFalse(relaunched.isComplete, "Closing is not completing setup")
    }

    func test_completionPersistsEvenIfAllAccountsAreLaterRemoved() {
        OnboardingState(defaults: defaults).complete()
        let relaunched = OnboardingState(defaults: defaults)
        XCTAssertTrue(relaunched.isComplete)
        XCTAssertFalse(relaunched.shouldPresentAutomatically(hasAccounts: false))
    }

    func test_verifiedTokenIsTrimmedAndSavedWithAccountIdentity() async {
        let accounts = makeAccounts()
        let connection = AccountConnectionStore { provider, token in
            XCTAssertEqual(provider, .github)
            XCTAssertEqual(token, "test-token")
            return "fixture-user"
        }
        connection.provider = .github
        connection.token = "  test-token\n"
        let result = await connection.connect(to: accounts)
        XCTAssertEqual(result?.label, "fixture-user")
        XCTAssertEqual(result?.provider, .github)
        XCTAssertEqual(accounts.token(for: result!), "test-token")
        XCTAssertEqual(connection.token, "")
        XCTAssertFalse(connection.isConnecting)
    }

    func test_settingsConnectionPreservesCustomAccountLabel() async {
        let accounts = makeAccounts()
        let connection = AccountConnectionStore { _, _ in "fixture-user" }
        connection.token = "test-token"
        let account = await connection.connect(to: accounts, label: "  Work projects  ")
        XCTAssertEqual(account?.label, "Work projects")
    }

    func test_accountSettingsRouteSelectsAccountsBeforeOpening() {
        let navigation = SettingsNavigation()
        var opened = false
        navigation.openSettings = {
            XCTAssertEqual(navigation.selection, .accounts)
            opened = true
        }
        navigation.showAccounts()
        XCTAssertTrue(opened)
    }

    func test_invalidTokenDoesNotCreateAccountAndCanBeRetried() async {
        let accounts = makeAccounts()
        var attempts = 0
        let connection = AccountConnectionStore { _, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.userAuthenticationRequired) }
            return "fixture-user"
        }
        connection.token = "invalid"
        let failed = await connection.connect(to: accounts)
        XCTAssertNil(failed)
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertNotNil(connection.errorMessage)
        XCTAssertFalse(connection.isConnecting)
        connection.token = "valid"
        let retried = await connection.connect(to: accounts)
        XCTAssertNotNil(retried)
        XCTAssertNil(connection.errorMessage)
    }

    func test_keychainFailureRollsBackAccount() async {
        let accounts = makeAccounts(credentials: FailingCredentials())
        let connection = AccountConnectionStore { _, _ in "fixture-user" }
        connection.token = "test-token"
        let result = await connection.connect(to: accounts)
        XCTAssertNil(result)
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertNotNil(connection.errorMessage)
    }

    func test_cancellationDoesNotSaveCredentials() async {
        let accounts = makeAccounts()
        let connection = AccountConnectionStore { _, _ in throw CancellationError() }
        connection.token = "test-token"
        let result = await connection.connect(to: accounts)
        XCTAssertNil(result)
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertNil(connection.errorMessage)
        XCTAssertFalse(connection.isConnecting)
    }

    func test_whitespaceTokenNeverReachesValidator() async {
        let accounts = makeAccounts()
        let connection = AccountConnectionStore { _, _ in
            XCTFail("Blank credentials must not be sent")
            return "fixture-user"
        }
        connection.token = " \n "
        XCTAssertFalse(connection.canConnect)
        let result = await connection.connect(to: accounts)
        XCTAssertNil(result)
    }

    private func makeAccounts(credentials: CredentialStore = InMemoryCredentialStore()) -> AccountStore {
        AccountStore(defaults: defaults, credentials: credentials,
                     detectCLI: { false }, reloadCLIToken: { nil },
                     detectGitHubCLI: { false }, reloadGitHubToken: { nil })
    }
}

private struct FailingCredentials: CredentialStore {
    func token(for account: String) -> String? { nil }
    func setToken(_ token: String, for account: String) {}
    func removeToken(for account: String) {}
}
