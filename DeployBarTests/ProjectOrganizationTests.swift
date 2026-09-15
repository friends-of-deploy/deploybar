import XCTest
@testable import DeployBar

/// The organization picker exists so a 350-repo account never renders every
/// row at once — these pin the grouping it relies on.
@MainActor
final class ProjectOrganizationTests: XCTestCase {
    private let account = Account.githubCLI(id: UUID(), label: "GitHub CLI")

    private func sourced(_ name: String, org: String?) -> SourcedProject {
        SourcedProject(project: Project(id: name, name: name, repoOrg: org),
                       account: account)
    }

    func test_organizationsAreAlphabeticalAndDeduplicated() {
        let projects = [
            sourced("zeta", org: "acme"),
            sourced("alpha", org: "Bravo"),
            sourced("beta", org: "acme"),
        ]
        XCTAssertEqual(AccountProjectsForm.organizations(of: projects), ["acme", "Bravo"])
    }

    func test_unlinkedProjectsSortLastSoTheyAreNeverTheDefault() {
        let projects = [
            sourced("loose", org: nil),
            sourced("owned", org: "acme"),
        ]
        let orgs = AccountProjectsForm.organizations(of: projects)
        XCTAssertEqual(orgs, ["acme", AccountProjectsForm.unlinkedKey])
        XCTAssertEqual(orgs.first, "acme", "the default selection must be a real owner")
    }

    func test_noUnlinkedBucketWhenEveryProjectHasAnOwner() {
        let projects = [sourced("owned", org: "acme")]
        XCTAssertEqual(AccountProjectsForm.organizations(of: projects), ["acme"])
    }

    func test_selectingAnOrganizationNarrowsToItsProjectsOnly() {
        let projects = [
            sourced("web", org: "acme"),
            sourced("api", org: "acme"),
            sourced("other", org: "bravo"),
        ]
        let acme = AccountProjectsForm.projects(projects, in: "acme")
        XCTAssertEqual(acme.map(\.project.name), ["api", "web"], "alphabetical, acme only")
    }

    func test_unlinkedProjectsAreReachableThroughTheirOwnBucket() {
        let projects = [
            sourced("loose", org: nil),
            sourced("owned", org: "acme"),
        ]
        let unlinked = AccountProjectsForm.projects(projects, in: AccountProjectsForm.unlinkedKey)
        XCTAssertEqual(unlinked.map(\.project.name), ["loose"],
                       "a project without a repo link must still be followable")
    }

    /// The whole point: no single picker selection renders the full account.
    func test_everyProjectBelongsToExactlyOneOrganization() {
        let projects = (0..<50).map { sourced("p\($0)", org: $0 % 2 == 0 ? "acme" : nil) }
        let orgs = AccountProjectsForm.organizations(of: projects)
        let grouped = orgs.flatMap { AccountProjectsForm.projects(projects, in: $0) }
        XCTAssertEqual(grouped.count, projects.count, "every project is reachable")
        XCTAssertEqual(Set(grouped.map(\.id)).count, projects.count, "and none is listed twice")
    }

    func test_pickerLabelCountsOnlyThatOrganizationsProjects() {
        let projects = [
            sourced("web", org: "acme"),
            sourced("api", org: "acme"),
            sourced("other", org: "bravo"),
        ]
        XCTAssertEqual(AccountProjectsForm.label(for: "acme", projects: projects), "acme (2)")
    }

    func test_unlinkedBucketHasAReadableLabel() {
        let projects = [sourced("loose", org: nil)]
        let label = AccountProjectsForm.label(for: AccountProjectsForm.unlinkedKey,
                                              projects: projects)
        XCTAssertFalse(label.hasPrefix(" ("), "the unlinked bucket needs a name, not a bare count")
        XCTAssertTrue(label.hasSuffix("(1)"))
    }
}
