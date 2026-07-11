import XCTest
@testable import DeployBar

final class AccountModelTests: XCTestCase {
    func test_provider_implementedProviders() {
        XCTAssertTrue(Provider.vercel.isImplemented)
        XCTAssertTrue(Provider.github.isImplemented)
        XCTAssertFalse(Provider.azureDevOps.isImplemented)
    }

    func test_provider_displayNames() {
        XCTAssertEqual(Provider.vercel.displayName, "Vercel")
        XCTAssertEqual(Provider.github.displayName, "GitHub")
        XCTAssertEqual(Provider.azureDevOps.displayName, "Azure DevOps")
    }

    func test_provider_codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Provider.vercel)
        XCTAssertEqual(try JSONDecoder().decode(Provider.self, from: data), .vercel)
    }
}

extension AccountModelTests {
    func test_account_codableRoundTrip() throws {
        let acct = Account(id: UUID(), provider: .vercel, label: "alice",
                           source: .keychain(account: "kc-1"))
        let data = try JSONEncoder().encode(acct)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: data), acct)
    }

    func test_account_cliIsReadOnly() {
        let cli = Account.vercelCLI(id: UUID(), label: "from CLI")
        XCTAssertTrue(cli.isReadOnly)
        XCTAssertEqual(cli.source, .vercelCLI)
        XCTAssertEqual(cli.provider, .vercel)
    }

    func test_account_keychainNotReadOnly() {
        let acct = Account(id: UUID(), provider: .vercel, label: "bob",
                           source: .keychain(account: "kc-2"))
        XCTAssertFalse(acct.isReadOnly)
    }

    func test_account_githubCLIIsReadOnly() {
        let gh = Account.githubCLI(id: UUID(), label: "from gh")
        XCTAssertTrue(gh.isReadOnly)
        XCTAssertEqual(gh.source, .githubCLI)
        XCTAssertEqual(gh.provider, .github)
    }

    func test_credentialSource_githubCLICodableRoundTrip() throws {
        let acct = Account.githubCLI(id: UUID(), label: "gh")
        let data = try JSONEncoder().encode(acct)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: data), acct)
    }

    func test_projectKey_storageRoundTrip() {
        let id = UUID()
        let key = ProjectKey(provider: .vercel, accountId: id, projectId: "prj_abc")
        let parsed = ProjectKey(storageString: key.storageString)
        XCTAssertEqual(parsed, key)
    }

    func test_projectKey_distinguishesAccounts() {
        let a = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "same")
        let b = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "same")
        XCTAssertNotEqual(a, b)               // same project name, different account → different key
        XCTAssertNotEqual(a.storageString, b.storageString)
    }

    func test_projectKey_rejectsMalformedString() {
        XCTAssertNil(ProjectKey(storageString: "garbage"))
    }

    func test_scope_id_personalVsTeam() {
        let acct = Account.vercelCLI(id: UUID(), label: "cli")
        let personal = Scope(account: acct, teamId: nil, teamName: nil)
        let team = Scope(account: acct, teamId: "team_1", teamName: "acme")
        XCTAssertTrue(personal.id.hasSuffix("personal"))
        XCTAssertTrue(team.id.hasSuffix("team_1"))
        XCTAssertEqual(personal.displayName, "personal")
        XCTAssertEqual(team.displayName, "acme")
    }

    func test_scopeFilter_matching() {
        let id = UUID()
        let acct = Account(id: id, provider: .vercel, label: "x", source: .keychain(account: "k"))
        XCTAssertTrue(ScopeFilter.all.matches(account: acct, teamId: "t"))
        XCTAssertTrue(ScopeFilter.provider(.vercel).matches(account: acct, teamId: nil))
        XCTAssertFalse(ScopeFilter.provider(.github).matches(account: acct, teamId: nil))
        XCTAssertTrue(ScopeFilter.account(id).matches(account: acct, teamId: "t"))
        XCTAssertFalse(ScopeFilter.account(UUID()).matches(account: acct, teamId: "t"))
        XCTAssertTrue(ScopeFilter.scope(accountId: id, teamId: "t").matches(account: acct, teamId: "t"))
        XCTAssertFalse(ScopeFilter.scope(accountId: id, teamId: "t").matches(account: acct, teamId: nil))
    }
}

extension AccountModelTests {
    func test_sourcedProject_keyAndId() throws {
        let acct = Account.vercelCLI(id: UUID(), label: "cli")
        let json = #"{"id":"prj_1","name":"web"}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        let sp = SourcedProject(project: project, account: acct)
        XCTAssertEqual(sp.id, "\(acct.id.uuidString)|prj_1")
        XCTAssertEqual(sp.key, ProjectKey(provider: .vercel, accountId: acct.id, projectId: "prj_1"))
    }
}
