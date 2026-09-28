import XCTest
@testable import DeployBar

/// Each provider names the one page a project as a whole opens on — the widget's
/// project link — without the caller switching on the provider.
final class ProjectPageURLTests: XCTestCase {

    func test_vercelOpensTheProjectDashboard() {
        let url = VercelIntegration().presentation.projectPageURL(Project(id: "prj_1", name: "web"), "acme")
        XCTAssertEqual(url?.absoluteString, "https://vercel.com/acme/web")
    }

    func test_gitHubOpensTheRepositoryActions() {
        let project = Project(id: "1", name: "octo/app", repoOrg: "octo", repoName: "app")
        let url = GitHubIntegration().presentation.projectPageURL(project, "")
        XCTAssertEqual(url?.absoluteString, "https://github.com/octo/app/actions")
    }

    func test_azureDevOpsOpensTheProjectPipelines() {
        let url = AzureDevOpsIntegration().presentation.projectPageURL(Project(id: "r1", name: "Fabrikam/web"), "contoso")
        XCTAssertEqual(url?.absoluteString, "https://dev.azure.com/contoso/Fabrikam/_build")
    }
}
