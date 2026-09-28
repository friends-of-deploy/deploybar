import Foundation

enum LinkBuilder {
    /// The primary target used by deployment rows.
    /// Provider pages win; failed Vercel builds prefer their logs over the live URL.
    static func deploymentDestination(for deployment: Deployment) -> URL? {
        if let web = deployment.webURL { return web }
        if deployment.state == .error {
            return deployment.inspectorUrl.flatMap(URL.init(string:))
                ?? liveURL(host: deployment.url)
        }
        return liveURL(host: deployment.url)
            ?? deployment.inspectorUrl.flatMap(URL.init(string:))
    }

    /// The deployment's own page — the Actions run or the Vercel inspector —
    /// used by the widgets, where a click means "show me this deploy", not
    /// "open the site it produced".
    static func deploymentPage(for deployment: Deployment) -> URL? {
        deployment.webURL
            ?? deployment.inspectorUrl.flatMap(URL.init(string:))
            ?? liveURL(host: deployment.url)
    }

    static func liveURL(host: String?) -> URL? {
        guard let host, !host.isEmpty else { return nil }
        return URL(string: "https://\(host)")
    }
    static func githubCommit(org: String?, repo: String?, sha: String?) -> URL? {
        guard let org, let repo, let sha, !org.isEmpty, !repo.isEmpty, !sha.isEmpty else { return nil }
        return URL(string: "https://github.com/\(org)/\(repo)/commit/\(sha)")
    }
    static func githubRepo(org: String?, repo: String?) -> URL? {
        guard let org, let repo, !org.isEmpty, !repo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(org)/\(repo)")
    }
    /// The repository page for a project row: the provider's own URL when it
    /// has one, else the GitHub page built from the linked repository.
    static func repository(for project: Project) -> URL? {
        project.repoURL ?? githubRepo(org: project.repoOrg, repo: project.repoName)
    }

    /// The commit page for a deployment row, by the same rule.
    static func commit(for deployment: Deployment) -> URL? {
        deployment.commitURL
            ?? githubCommit(org: deployment.commitOrg, repo: deployment.commitRepo, sha: deployment.commitSha)
    }
    /// The repository's GitHub Actions overview page.
    static func githubActions(org: String?, repo: String?) -> URL? {
        githubPage(org: org, repo: repo, path: "/actions")
    }
    /// The repository's open pull requests.
    static func githubPulls(org: String?, repo: String?) -> URL? {
        githubPage(org: org, repo: repo, path: "/pulls")
    }
    /// The repository's open issues.
    static func githubIssues(org: String?, repo: String?) -> URL? {
        githubPage(org: org, repo: repo, path: "/issues")
    }
    /// The repository's settings page.
    static func githubRepoSettings(org: String?, repo: String?) -> URL? {
        githubPage(org: org, repo: repo, path: "/settings")
    }

    private static func githubPage(org: String?, repo: String?, path: String) -> URL? {
        guard let org, let repo, !org.isEmpty, !repo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(org)/\(repo)\(path)")
    }

    // MARK: - Vercel dashboard deep links

    /// The project's page on vercel.com.
    static func projectDashboard(scope: String, project: String) -> URL? {
        projectPage(scope: scope, project: project, path: "")
    }
    /// The project's Environment Variables settings page.
    static func projectEnv(scope: String, project: String) -> URL? {
        projectPage(scope: scope, project: project, path: "/settings/environment-variables")
    }
    /// The project's Analytics page.
    static func projectAnalytics(scope: String, project: String) -> URL? {
        projectPage(scope: scope, project: project, path: "/analytics")
    }
    /// The project's general Settings page.
    static func projectSettings(scope: String, project: String) -> URL? {
        projectPage(scope: scope, project: project, path: "/settings")
    }

    private static func projectPage(scope: String, project: String, path: String) -> URL? {
        guard !scope.isEmpty, !project.isEmpty else { return nil }
        return URL(string: "https://vercel.com/\(scope)/\(project)\(path)")
    }
}
