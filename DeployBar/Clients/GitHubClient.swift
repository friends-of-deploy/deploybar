import Foundation
import os

/// Read-only GitHub Actions client. Maps repositories to `Project`s and workflow
/// runs to `Deployment`s so GitHub sources merge into the same aggregator surface
/// as Vercel. Injects a `fetch` closure for testing, mirroring `VercelClient`.
///
/// GitHub has no single "all my workflow runs" endpoint, so `deployments(limit:)`
/// fans out one runs request per repository. To stay well under the REST rate
/// limit (5000 req/hour authenticated) the fan-out is bounded to the most
/// recently pushed repos via `runFanoutLimit`.
struct GitHubClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let decoder = JSONDecoder()

    let token: String
    /// Organization this client is scoped to, or nil for the account itself.
    /// A scoped client lists only that org's repositories, so a disabled
    /// organization costs no requests at all.
    let org: String?
    /// Number of most-recently-pushed repos to fetch workflow runs for per poll.
    let runFanoutLimit: Int
    let fetch: Fetch

    /// Runaway guard for repository listing pagination.
    private let maxRepoPages = 10

    init(token: String,
         org: String? = nil,
         runFanoutLimit: Int = 20,
         fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.token = token
        self.org = org
        self.runFanoutLimit = max(1, runFanoutLimit)
        self.fetch = fetch
    }

    // MARK: - DeploymentProviderClient surface

    func projects() async throws -> [Project] {
        try await repositories(maxPages: maxRepoPages, perPage: 100).map(Self.project(from:))
    }

    func deployments(limit: Int) async throws -> [Deployment] {
        // A single page of most-recently-pushed repos bounds the fan-out.
        let repos = try await repositories(maxPages: 1, perPage: runFanoutLimit)
        guard !repos.isEmpty else { return [] }
        let perRepo = min(100, max(1, limit / repos.count) + 5)

        // Per-repo failures stay best-effort — one repo with Actions disabled or
        // a PAT scope gap must not blank the whole account. Throttling is the
        // exception: it would silently empty the list for every repo at once and
        // read as "no deployments", so it is reported instead of swallowed.
        let merged = await withTaskGroup(of: Result<[Deployment], Error>.self) { group in
            for repo in repos {
                group.addTask {
                    do { return .success(try await self.runs(for: repo, perPage: perRepo)) }
                    catch { return .failure(error) }
                }
            }
            var all: [Deployment] = []
            var throttled: ProviderClientError?
            for await chunk in group {
                switch chunk {
                case .success(let deps):
                    all.append(contentsOf: deps)
                case .failure(let error):
                    if case ProviderClientError.rateLimited = error {
                        throttled = error as? ProviderClientError
                    } else {
                        os_log("github runs fetch failed for a repo: %{public}@",
                               error.localizedDescription)
                    }
                }
            }
            return (all, throttled)
        }
        // Only when throttling left us with nothing at all: a partial result
        // is still worth showing.
        if let throttled = merged.1, merged.0.isEmpty { throw throttled }
        return Array(merged.0.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    /// Confirms the token belongs to a GitHub account without loading repositories.
    func authenticatedLogin() async throws -> String {
        struct Identity: Decodable { let login: String }
        let data = try await get(path: "/user", query: [])
        return try Self.decoder.decode(Identity.self, from: data).login
    }

    // MARK: - Requests

    /// Lists the authenticated user's repositories, most recently pushed first.
    /// Follows `page` until a short page is returned or the page cap is hit.
    private func repositories(maxPages: Int, perPage: Int) async throws -> [GHRepo] {
        var all: [GHRepo] = []
        for page in 1...max(1, maxPages) {
            var query = [
                URLQueryItem(name: "sort", value: "pushed"),
                URLQueryItem(name: "per_page", value: String(perPage)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            let path: String
            if let org {
                path = "/orgs/\(org)/repos"
            } else {
                path = "/user/repos"
                // Owned repos only. Organization repositories arrive through
                // their own scope; listing them here too would show every repo
                // twice and give it the account's marker instead of the org's.
                query.append(URLQueryItem(name: "affiliation", value: "owner"))
            }
            let data = try await get(path: path, query: query)
            let batch = try Self.decoder.decode([GHRepo].self, from: data)
            all.append(contentsOf: batch)
            if batch.count < perPage { break }
        }
        return all
    }

    /// Builds a paste-ready failure report for a run: its failed jobs/steps plus
    /// the tail of the first failed job's log (log fetch is best-effort).
    /// `deployment.name` is the repo full name and `deployment.uid` is the run id.
    func failureReport(for deployment: Deployment) async throws -> String {
        let repo = deployment.name
        let runId = deployment.uid
        let data = try await get(path: "/repos/\(repo)/actions/runs/\(runId)/jobs", query: [])
        let jobs = try Self.decoder.decode(GHJobsResponse.self, from: data).jobs
        let failed = jobs.filter { GitHubActionsErrorReport.isFailure($0.conclusion) }

        var logTail: String?
        if let job = failed.first {
            logTail = try? await jobLog(repoFullName: repo, jobId: job.id)
        }
        return GitHubActionsErrorReport.make(deployment: deployment, failedJobs: failed, logTail: logTail)
    }

    /// Plain-text log for a single job. GitHub 302-redirects to a storage host;
    /// URLSession follows it. Best-effort — callers tolerate a throw.
    private func jobLog(repoFullName: String, jobId: Int) async throws -> String {
        let data = try await get(path: "/repos/\(repoFullName)/actions/jobs/\(jobId)/logs", query: [])
        return String(decoding: data, as: UTF8.self)
    }

    private func runs(for repo: GHRepo, perPage: Int) async throws -> [Deployment] {
        let data = try await get(path: "/repos/\(repo.fullName)/actions/runs",
                                 query: [URLQueryItem(name: "per_page", value: String(perPage))])
        let response = try Self.decoder.decode(GHRunsResponse.self, from: data)
        return response.workflowRuns.map { Self.deployment(from: $0, repo: repo) }
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        var comps = URLComponents(string: "https://api.github.com\(path)")!
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("DeployBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await fetch(req)
        guard let http = response as? HTTPURLResponse else { throw ProviderClientError.http(-1) }
        // Before the auth check: GitHub signals an exhausted rate limit with
        // 403, which must not be mistaken for a revoked token.
        if http.isRateLimited { throw ProviderClientError.rateLimited(retryAfter: http.retryAfterSeconds) }
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ProviderClientError.http(http.statusCode) }
        return data
    }

    // MARK: - Mapping

    static func project(from repo: GHRepo) -> Project {
        Project(
            id: repo.fullName,
            name: repo.fullName,
            repoType: "github",
            repoOrg: repo.owner.login,
            repoName: repo.name,
            productionBranch: repo.defaultBranch,
            productionURL: host(fromHomepage: repo.homepage),
            productionAliases: [],
            framework: repo.language,          // primary language fills the framework chip
            starCount: repo.stargazersCount,
            openIssueCount: repo.openIssuesCount,
            isPrivate: repo.isPrivate,
            pushedAt: epochMs(repo.pushedAt),
            iconURL: repo.owner.avatarURL
        )
    }

    static func deployment(from run: GHRun, repo: GHRepo) -> Deployment {
        Deployment(
            uid: String(run.id),
            name: repo.fullName,
            stateRaw: githubState(status: run.status, conclusion: run.conclusion),
            target: run.headBranch,
            url: "",                                   // GitHub uses webURL, not a bare host
            inspectorUrl: nil,
            createdAt: epochMs(run.createdAt) ?? 0,
            buildingAt: epochMs(run.runStartedAt ?? run.createdAt),
            ready: run.status == "completed" ? epochMs(run.updatedAt ?? run.createdAt) : nil,
            creatorUsername: run.actor?.login,
            commitOrg: repo.owner.login,
            commitRepo: repo.name,
            commitSha: run.headSHA,
            commitRef: run.headBranch,
            commitMessage: run.displayTitle ?? run.headCommit?.message ?? run.name,
            // `actor` is who the run ran as and carries a ready avatar; the commit's
            // own author has only a name/email on the run payload, so it serves as
            // the display-name fallback when there is no actor to show.
            commitAuthorLogin: run.actor?.login ?? run.headCommit?.author?.name,
            commitAuthorAvatarURL: run.actor?.avatarURL,
            webURL: URL(string: run.htmlURL)
        )
    }

    /// GitHub `homepage` is free text — often a full URL, sometimes a bare host.
    /// The shared `Project` model carries bare hosts (Vercel-style), which feed
    /// both the live-site link and the favicon fetch, so extract one.
    static func host(fromHomepage homepage: String?) -> String? {
        guard let homepage, !homepage.isEmpty else { return nil }
        if let url = URL(string: homepage), let host = url.host { return host }
        return homepage.split(separator: "/").first.map(String.init)
    }

    /// Maps GitHub run `status`/`conclusion` onto the Vercel-shaped tokens that
    /// `DeploymentState(apiValue:)` already understands, so no model change is needed.
    static func githubState(status: String?, conclusion: String?) -> String {
        switch status {
        case "completed":
            switch conclusion {
            case "success":                              return "READY"
            case "failure", "timed_out", "startup_failure": return "ERROR"
            case "cancelled":                            return "CANCELED"
            default:                                     return "UNKNOWN"   // skipped/neutral/action_required/stale
            }
        case "in_progress":                              return "BUILDING"
        case "queued", "requested", "waiting", "pending": return "QUEUED"
        default:                                         return "UNKNOWN"
        }
    }

    private static let iso = ISO8601DateFormatter()

    /// GitHub timestamps are ISO-8601 (`2024-01-15T10:30:00Z`); the app's timing
    /// helpers expect epoch **milliseconds** (matching Vercel), so scale up.
    static func epochMs(_ iso8601: String?) -> Double? {
        guard let s = iso8601, let date = iso.date(from: s) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }
}

extension GitHubClient: DeploymentProviderClient {}
