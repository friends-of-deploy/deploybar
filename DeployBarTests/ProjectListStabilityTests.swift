import XCTest
@testable import DeployBar

/// The projects list is assembled from a `TaskGroup`, so its results arrive in
/// completion order. Without an explicit sort the same set of projects came back
/// in a different order on each poll and the list visibly reshuffled a moment
/// after the popover opened. These pin the order down.
@MainActor
final class ProjectListStabilityTests: XCTestCase {

    private struct SlowStub: DeploymentProviderClient {
        var projs: [Project]
        /// Staggers completion so the task group finishes in a controlled —
        /// and deliberately *wrong* — order.
        var delay: Duration

        func deployments(limit: Int) async throws -> [Deployment] { [] }
        func projects() async throws -> [Project] {
            try? await Task.sleep(for: delay)
            return projs
        }
    }

    private func project(id: String, name: String) -> Project {
        Project(id: id, name: name)
    }

    /// Two accounts, and the one whose projects sort *first* answers *last*.
    /// Completion order would put "zeta" above "alpha".
    func test_projectsAreAlphabeticalRegardlessOfWhichSourceAnswersFirst() async {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false },
                                        reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        let fast = accountStore.addKeychainAccount(provider: .vercel, label: "Fast", token: "t1")
        _ = accountStore.addKeychainAccount(provider: .vercel, label: "Slow", token: "t2")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let store = DeploymentStore(
            accountStore: accountStore,
            settings: settings,
            makeClient: { [fast] account, _ in
                if account.id == fast.id {
                    return SlowStub(projs: [Project(id: "z", name: "zeta")], delay: .zero)
                }
                return SlowStub(projs: [Project(id: "a", name: "alpha")],
                                delay: .milliseconds(40))
            },
            reloadToken: { nil },
            authRetryBackoff: .zero)

        await store.poll()
        XCTAssertEqual(store.sourcedProjects.map(\.project.name), ["alpha", "zeta"],
                       "the slow source's project still sorts first")
    }

    /// The actual symptom the user reported: poll twice, get the same order.
    func test_repeatedPollsDoNotReorderTheList() async {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false },
                                        reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        let a = accountStore.addKeychainAccount(provider: .vercel, label: "A", token: "t1")
        _ = accountStore.addKeychainAccount(provider: .vercel, label: "B", token: "t2")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        // Each poll flips which source is slow, so completion order genuinely
        // differs between the two polls.
        var flip = false
        let store = DeploymentStore(
            accountStore: accountStore,
            settings: settings,
            makeClient: { [a] account, _ in
                let isA = account.id == a.id
                let slow = isA == flip
                return SlowStub(projs: isA
                                ? [Project(id: "m", name: "middle")]
                                : [Project(id: "a", name: "aardvark"),
                                   Project(id: "z", name: "zulu")],
                                delay: slow ? .milliseconds(40) : .zero)
            },
            reloadToken: { nil },
            authRetryBackoff: .zero)

        await store.poll()
        let first = store.sourcedProjects.map(\.id)
        flip = true
        await store.poll()
        XCTAssertEqual(store.sourcedProjects.map(\.id), first,
                       "a second poll must not reshuffle the list")
        XCTAssertEqual(store.sourcedProjects.map(\.project.name),
                       ["aardvark", "middle", "zulu"])
    }

    /// Case differences must not split the list into two alphabets.
    func test_orderingIsCaseInsensitive() {
        let account = Account.githubCLI(id: UUID(), label: "GitHub CLI")
        let sourced = [
            SourcedProject(project: Project(id: "1", name: "Zebra"), account: account),
            SourcedProject(project: Project(id: "2", name: "apple"), account: account),
            SourcedProject(project: Project(id: "3", name: "Banana"), account: account),
        ]
        XCTAssertEqual(sourced.sorted(by: SourcedProject.displayOrder).map(\.project.name),
                       ["apple", "Banana", "Zebra"])
    }

    /// Two projects sharing a name still need a fixed order, or the sort itself
    /// becomes a source of reshuffling.
    func test_projectsSharingANameAreOrderedByIdentity() {
        let account = Account.githubCLI(id: UUID(), label: "GitHub CLI")
        let one = SourcedProject(project: Project(id: "aaa", name: "web"), account: account)
        let two = SourcedProject(project: Project(id: "bbb", name: "web"), account: account)
        XCTAssertEqual([two, one].sorted(by: SourcedProject.displayOrder).map(\.project.id),
                       ["aaa", "bbb"])
        XCTAssertEqual([one, two].sorted(by: SourcedProject.displayOrder).map(\.project.id),
                       ["aaa", "bbb"])
    }
}
