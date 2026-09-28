import XCTest
@testable import DeployBar

@MainActor
final class ProviderNeutralModelTests: XCTestCase {

    // MARK: Account.organization

    /// Accounts saved by 1.2.x have no `organization` key.
    func test_accountSavedBeforeOrganizationsDecodes() throws {
        let json = #"[{"id":"8B1C2D3E-0000-0000-0000-000000000001","provider":"github","label":"G","source":{"keychain":{"account":"k"}}}]"#
        let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
        XCTAssertEqual(accounts.first?.label, "G")
        XCTAssertNil(accounts.first?.organization)
    }

    func test_organizationSurvivesARoundTrip() throws {
        let account = Account(id: UUID(), provider: .azureDevOps, label: "ADO",
                              source: .keychain(account: "k"), organization: "contoso")
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded, account)
    }

    func test_addedAccountKeepsItsOrganizationAcrossLaunches() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let credentials = InMemoryCredentialStore()
        let store = AccountStore(defaults: defaults, credentials: credentials,
                                 detectCLI: { false }, detectGitHubCLI: { false })
        let added = store.addKeychainAccount(provider: .azureDevOps, label: "ADO", token: "t", organization: "contoso")
        let relaunched = AccountStore(defaults: defaults, credentials: credentials,
                                      detectCLI: { false }, detectGitHubCLI: { false })
        XCTAssertEqual(relaunched.accounts.first { $0.id == added.id }?.organization, "contoso")
    }

    // MARK: Provider-neutral links

    func test_commitLinkPrefersTheProvidersOwn() {
        let own = Deployment(uid: "1", name: "p/r", stateRaw: "READY", url: "", createdAt: 1,
                             commitOrg: "acme", commitRepo: "web", commitSha: "abc",
                             commitURL: URL(string: "https://dev.azure.com/o/p/_git/r/commit/abc"))
        XCTAssertEqual(LinkBuilder.commit(for: own)?.absoluteString, "https://dev.azure.com/o/p/_git/r/commit/abc")
        let github = Deployment(uid: "2", name: "acme/web", stateRaw: "READY", url: "", createdAt: 1,
                                commitOrg: "acme", commitRepo: "web", commitSha: "abc")
        XCTAssertEqual(LinkBuilder.commit(for: github)?.absoluteString, "https://github.com/acme/web/commit/abc")
        XCTAssertNil(LinkBuilder.commit(for: Deployment(uid: "3", name: "x", stateRaw: "READY", url: "", createdAt: 1)))
    }

    func test_repositoryLinkPrefersTheProvidersOwn() {
        let own = Project(id: "r", name: "Shop/web", repoName: "web",
                          repoURL: URL(string: "https://dev.azure.com/o/Shop/_git/web"))
        XCTAssertEqual(LinkBuilder.repository(for: own)?.absoluteString, "https://dev.azure.com/o/Shop/_git/web")
        let github = Project(id: "acme/web", name: "acme/web", repoOrg: "acme", repoName: "web")
        XCTAssertEqual(LinkBuilder.repository(for: github)?.absoluteString, "https://github.com/acme/web")
        XCTAssertNil(LinkBuilder.repository(for: Project(id: "p", name: "web")))
    }

    // MARK: Row cache

    func test_rowCacheKeepsProviderLinks() {
        let account = Account(id: UUID(), provider: .azureDevOps, label: "ADO", source: .keychain(account: "k"))
        let deployment = Deployment(uid: "p:1", name: "Shop/web", stateRaw: "READY", url: "", createdAt: 1,
                                    commitURL: URL(string: "https://dev.azure.com/o/Shop/_git/web/commit/abc"))
        let project = Project(id: "r", name: "Shop/web", repoURL: URL(string: "https://dev.azure.com/o/Shop/_git/web"))
        let byId = [account.id: account]
        let restoredDeployment = RowCache.CachedDeployment(
            SourcedDeployment(deployment: deployment, account: account, teamId: "o")).restore(accounts: byId)
        let restoredProject = RowCache.CachedProject(
            SourcedProject(project: project, account: account, teamId: "o")).restore(accounts: byId)
        XCTAssertEqual(restoredDeployment?.deployment.commitURL, deployment.commitURL)
        XCTAssertEqual(restoredProject?.project.repoURL, project.repoURL)
    }
}
