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

    func test_deploymentPage_prefersProviderPageThenInspectorThenLive() {
        let gh = Deployment(uid: "1", name: "r", stateRaw: "READY", url: "",
                            createdAt: 0, webURL: URL(string: "https://github.com/o/r/actions/runs/1"))
        XCTAssertEqual(LinkBuilder.deploymentPage(for: gh)?.absoluteString, "https://github.com/o/r/actions/runs/1")
        let vercel = Deployment(uid: "2", name: "w", stateRaw: "READY", url: "w-abc.vercel.app",
                                inspectorUrl: "https://vercel.com/acme/w/2", createdAt: 0)
        XCTAssertEqual(LinkBuilder.deploymentPage(for: vercel)?.absoluteString, "https://vercel.com/acme/w/2")
        let bare = Deployment(uid: "3", name: "w", stateRaw: "READY", url: "w-abc.vercel.app", createdAt: 0)
        XCTAssertEqual(LinkBuilder.deploymentPage(for: bare)?.absoluteString, "https://w-abc.vercel.app")
    }
}
