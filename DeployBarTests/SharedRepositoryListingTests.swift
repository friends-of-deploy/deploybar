import XCTest
@testable import DeployBar

/// GitHub organization scopes all read the same `/user/repos` listing and keep
/// their owner's repositories. The store lists once per tick for all of them,
/// instead of twice per organization (projects and deployments).
@MainActor
final class SharedRepositoryListingTests: XCTestCase {

    private actor ListingLog {
        private(set) var queries: [String] = []
        func add(_ query: String) { queries.append(query) }
    }

    private static func team(_ id: String) -> Team {
        try! JSONDecoder().decode(Team.self, from: Data(#"{"id":"\#(id)","slug":"\#(id)","name":"\#(id)"}"#.utf8))
    }

    /// A GitHub CLI account with three organizations and an hour-long interval,
    /// so a single tick can afford every scope.
    private func makeStore(log: ListingLog) -> DeploymentStore {
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(),
                                    detectCLI: { false }, reloadCLIToken: { nil },
                                    detectGitHubCLI: { true }, reloadGitHubToken: { "tok" })
        let account = accounts.githubCLIAccount!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.pollIntervalSeconds = 3600
        settings.cachedOrgs = [account.id: ["acme", "beta", "gamma"].map(Self.team)]
        return DeploymentStore(accountStore: accounts, settings: settings,
                               gitHubFetch: { req in
                                   let isListing = req.url!.path == "/user/repos"
                                   if isListing { await log.add(req.url!.query ?? "") }
                                   let body = isListing ? "[]" : #"{"workflow_runs":[]}"#
                                   let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                                              httpVersion: nil, headerFields: nil)!
                                   return (Data(body.utf8), resp)
                               },
                               now: SteppingClock(step: 3600).next,
                               reloadToken: { nil }, authRetryBackoff: .zero)
    }

    /// Listings without `affiliation`: the organizations' ones, not the personal scope's.
    private func organizationListings(_ log: ListingLog) async -> Int {
        await log.queries.filter { !$0.contains("affiliation") }.count
    }

    func test_organizationScopesOfOneTickShareOneListing() async {
        let log = ListingLog()
        let store = makeStore(log: log)

        await store.poll()

        let listings = await organizationListings(log)
        XCTAssertEqual(listings, 1, "three organizations, projects and runs each: one listing")
    }

    func test_eachTickListsAfresh() async {
        let log = ListingLog()
        let store = makeStore(log: log)

        await store.poll()
        await store.poll()

        let listings = await organizationListings(log)
        XCTAssertEqual(listings, 2, "a push since the last tick must show up")
    }
}
