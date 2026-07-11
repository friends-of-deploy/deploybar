import Foundation

enum LinkBuilder {
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
    /// The repository's GitHub Actions overview page.
    static func githubActions(org: String?, repo: String?) -> URL? {
        guard let org, let repo, !org.isEmpty, !repo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(org)/\(repo)/actions")
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
