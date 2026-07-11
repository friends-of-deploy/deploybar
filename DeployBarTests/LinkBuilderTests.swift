import XCTest
@testable import DeployBar

final class LinkBuilderTests: XCTestCase {
    func test_deploymentLiveURL_prefixesHTTPS() {
        XCTAssertEqual(LinkBuilder.liveURL(host: "dashboard-abc.vercel.app")?.absoluteString,
                       "https://dashboard-abc.vercel.app")
    }
    func test_githubCommitURL() {
        let u = LinkBuilder.githubCommit(org: "acme", repo: "app", sha: "7cb0cc1")
        XCTAssertEqual(u?.absoluteString, "https://github.com/acme/app/commit/7cb0cc1")
    }
    func test_githubRepoURL() {
        XCTAssertEqual(LinkBuilder.githubRepo(org: "acme", repo: "web-app")?.absoluteString,
                       "https://github.com/acme/web-app")
    }
    func test_missingPiecesReturnNil() {
        XCTAssertNil(LinkBuilder.githubCommit(org: nil, repo: "app", sha: "x"))
        XCTAssertNil(LinkBuilder.liveURL(host: nil))
        XCTAssertNil(LinkBuilder.githubRepo(org: "acme", repo: nil))
        XCTAssertNil(LinkBuilder.githubPulls(org: "", repo: "app"))
    }

    func test_githubRepoDeepLinks() {
        XCTAssertEqual(LinkBuilder.githubPulls(org: "acme", repo: "web")?.absoluteString,
                       "https://github.com/acme/web/pulls")
        XCTAssertEqual(LinkBuilder.githubIssues(org: "acme", repo: "web")?.absoluteString,
                       "https://github.com/acme/web/issues")
        XCTAssertEqual(LinkBuilder.githubRepoSettings(org: "acme", repo: "web")?.absoluteString,
                       "https://github.com/acme/web/settings")
    }

    func test_homepageHostNormalization() {
        XCTAssertEqual(GitHubClient.host(fromHomepage: "https://acme.dev"), "acme.dev")
        XCTAssertEqual(GitHubClient.host(fromHomepage: "https://acme.dev/docs"), "acme.dev")
        XCTAssertEqual(GitHubClient.host(fromHomepage: "acme.dev"), "acme.dev")
        XCTAssertNil(GitHubClient.host(fromHomepage: ""))
        XCTAssertNil(GitHubClient.host(fromHomepage: nil))
    }

    func test_projectDashboardDeepLinks() {
        XCTAssertEqual(LinkBuilder.projectDashboard(scope: "acme", project: "dashboard")?.absoluteString,
                       "https://vercel.com/acme/dashboard")
        XCTAssertEqual(LinkBuilder.projectEnv(scope: "acme", project: "dashboard")?.absoluteString,
                       "https://vercel.com/acme/dashboard/settings/environment-variables")
        XCTAssertEqual(LinkBuilder.projectAnalytics(scope: "acme", project: "dashboard")?.absoluteString,
                       "https://vercel.com/acme/dashboard/analytics")
        XCTAssertEqual(LinkBuilder.projectSettings(scope: "acme", project: "dashboard")?.absoluteString,
                       "https://vercel.com/acme/dashboard/settings")
    }

    func test_projectDeepLinksNilWhenEmpty() {
        XCTAssertNil(LinkBuilder.projectEnv(scope: "", project: "dashboard"))
        XCTAssertNil(LinkBuilder.projectAnalytics(scope: "acme", project: ""))
    }
}
