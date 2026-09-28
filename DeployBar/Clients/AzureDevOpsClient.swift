import Foundation
import os

/// Read-only Azure DevOps client for one organization. Repositories map to
/// `Project`s and pipeline runs (builds) to `Deployment`s, so Azure DevOps
/// merges into the same aggregator surface as Vercel and GitHub.
///
/// Builds are listed per ADO project; there is no organization-wide list, so
/// `deployments(limit:)` fans out one request per project, capped at the most
/// recently updated `projectFanoutLimit`.
struct AzureDevOpsClient: Sendable {
    private static let decoder = JSONDecoder()

    let organization: String
    let token: String
    let projectFanoutLimit: Int
    let fetch: HTTPFetch

    /// Build lists fetched per scope and poll.
    static let maxProjectRequestsPerScope = 20
    /// The project list, the repository list, and the build fan-out.
    static let maxRequestsPerScope = 2 + maxProjectRequestsPerScope

    init(organization: String, token: String,
         projectFanoutLimit: Int = AzureDevOpsClient.maxProjectRequestsPerScope,
         fetch: @escaping HTTPFetch = { try await URLSession.shared.data(for: $0) }) {
        self.organization = organization
        self.token = token
        self.projectFanoutLimit = max(1, projectFanoutLimit)
        self.fetch = fetch
    }

    // MARK: - DeploymentProviderClient surface

    func projects() async throws -> [Project] {
        let data = try await get("_apis/git/repositories")
        return try Self.decoder.decode(ADOList<ADORepository>.self, from: data).value
            .filter { $0.isDisabled != true }
            .map(Self.project(from:))
    }

    func deployments(limit: Int) async throws -> [Deployment] {
        let listed = try Self.decoder.decode(ADOList<ADOProject>.self,
                                             from: try await get("_apis/projects", query: [URLQueryItem(name: "$top", value: "100")]))
            .value
        let projects = Array(listed
            .sorted { (Self.epochMs($0.lastUpdateTime) ?? 0) > (Self.epochMs($1.lastUpdateTime) ?? 0) }
            .prefix(projectFanoutLimit))
        guard !projects.isEmpty else { return [] }
        let perProject = min(100, max(1, limit / projects.count) + 5)

        // Per-project failures stay best-effort, like GitHub's per-repo fan-out;
        // throttling is reported when it left nothing to show.
        let merged = await withTaskGroup(of: Result<[Deployment], Error>.self) { group in
            for project in projects {
                group.addTask {
                    do { return .success(try await self.builds(inProject: project.id, top: perProject)) }
                    catch { return .failure(error) }
                }
            }
            var all: [Deployment] = []
            var throttled: ProviderClientError?
            for await chunk in group {
                switch chunk {
                case .success(let runs): all.append(contentsOf: runs)
                case .failure(let error):
                    if case ProviderClientError.rateLimited = error {
                        throttled = error as? ProviderClientError
                    } else {
                        os_log("azure devops builds fetch failed for a project: %{public}@", error.localizedDescription)
                    }
                }
            }
            return (all, throttled)
        }
        if let throttled = merged.1, merged.0.isEmpty { throw throttled }
        return Array(merged.0.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    /// Re-reads runs by id: one request per ADO project. A run that can't be
    /// read is left out, so its row keeps its last state.
    func refreshed(_ deployments: [Deployment]) async throws -> [Deployment] {
        let byProject = Dictionary(grouping: deployments.compactMap(Self.buildRef), by: \.project)
        return await withTaskGroup(of: [Deployment].self) { group in
            for (project, refs) in byProject {
                group.addTask {
                    do {
                        let ids = refs.map(\.buildId).joined(separator: ",")
                        let data = try await self.get("\(project)/_apis/build/builds",
                                                      query: [URLQueryItem(name: "buildIds", value: ids)])
                        return try Self.decoder.decode(ADOList<ADOBuild>.self, from: data).value
                            .map { Self.deployment(from: $0, organization: self.organization) }
                    } catch {
                        os_log("azure devops run refresh failed: %{public}@", error.localizedDescription)
                        return []
                    }
                }
            }
            return await group.reduce(into: [Deployment]()) { $0.append(contentsOf: $1) }
        }
    }

    /// Paste-ready failure report: failed tasks from the run's timeline plus
    /// the tail of the first failed record's log (best-effort). Falls back to
    /// failed jobs when no task failed — a job can fail before any task runs
    /// (no agent, job condition, infrastructure timeout).
    func failureReport(for deployment: Deployment) async throws -> String {
        guard let ref = Self.buildRef(deployment) else { throw ProviderClientError.http(-1) }
        let data = try await get("\(ref.project)/_apis/build/builds/\(ref.buildId)/timeline")
        let records = try Self.decoder.decode(ADOTimeline.self, from: data).records
        let failedTasks = records
            .filter { $0.type == "Task" && $0.result == "failed" }
            .sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        let failed = failedTasks.isEmpty
            ? records.filter { $0.type == "Job" && $0.result == "failed" }.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            : failedTasks
        var logTail: String?
        if let logId = failed.first(where: { $0.log != nil })?.log?.id,
           let log = try? await get("\(ref.project)/_apis/build/builds/\(ref.buildId)/logs/\(logId)",
                                    accept: "text/plain") {
            logTail = String(decoding: log, as: UTF8.self)
        }
        return AzureDevOpsErrorReport.make(deployment: deployment, failedRecords: failed, logTail: logTail)
    }

    /// The display name the token belongs to, without loading anything else.
    func authenticatedName() async throws -> String {
        let data = try await get("_apis/connectionData", apiVersion: nil)
        let user = try Self.decoder.decode(ADOConnectionData.self, from: data).authenticatedUser
        return user.providerDisplayName ?? organization
    }

    // MARK: - Requests

    private func builds(inProject project: String, top: Int) async throws -> [Deployment] {
        let data = try await get("\(project)/_apis/build/builds", query: [
            URLQueryItem(name: "$top", value: String(top)),
            URLQueryItem(name: "queryOrder", value: "queueTimeDescending"),
        ])
        return try Self.decoder.decode(ADOList<ADOBuild>.self, from: data).value
            .map { Self.deployment(from: $0, organization: organization) }
    }

    private func get(_ path: String, query: [URLQueryItem] = [], apiVersion: String? = "7.1",
                     accept: String = "application/json") async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dev.azure.com"
        components.path = "/\(organization)/\(path)"
        let version = apiVersion.map { [URLQueryItem(name: "api-version", value: $0)] } ?? []
        components.queryItems = (version + query).isEmpty ? nil : version + query
        var request = URLRequest(url: components.url!)
        request.setValue(Self.basicAuthorization(token), forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        try Self.check(response)
        return data
    }

    static func basicAuthorization(_ token: String) -> String {
        "Basic " + Data(":\(token)".utf8).base64EncodedString()
    }

    /// Shared by every Azure DevOps request. A rejected PAT gets a 203 with an
    /// HTML sign-in page rather than a 401, so 203 counts as unauthorized too.
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ProviderClientError.http(-1) }
        if http.isRateLimited { throw ProviderClientError.rateLimited(retryAfter: http.retryAfterSeconds) }
        if [203, 401, 403].contains(http.statusCode) { throw ProviderClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ProviderClientError.http(http.statusCode) }
    }

    // MARK: - Mapping

    /// The ADO project and build a deployment's `uid` ("<projectId>:<buildId>") points at.
    struct BuildRef: Hashable { let project: String; let buildId: String }

    static func buildRef(_ deployment: Deployment) -> BuildRef? {
        let parts = deployment.uid.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return BuildRef(project: parts[0], buildId: parts[1])
    }

    static func project(from repo: ADORepository) -> Project {
        Project(
            id: repo.id,
            name: "\(repo.project.name)/\(repo.name)",
            repoType: "azureRepos",
            repoName: repo.name,
            productionBranch: repo.defaultBranch.map(branchName),
            repoURL: repo.webUrl.flatMap(URL.init(string:))
        )
    }

    static func deployment(from build: ADOBuild, organization: String) -> Deployment {
        let projectName = build.project?.name ?? ""
        let repoName = build.repository?.name ?? build.definition?.name ?? "build \(build.id)"
        let branch = build.sourceBranch.map(branchName)
        // A GitHub repository built by an ADO pipeline keeps GitHub's own commit link.
        let gitHub = build.repository?.type == "GitHub"
            ? build.repository?.name.split(separator: "/", maxSplits: 1).map(String.init) : nil
        let fallbackTitle = build.definition.map { "\($0.name) #\(build.buildNumber ?? String(build.id))" }
        return Deployment(
            uid: "\(build.project?.id ?? ""):\(build.id)",
            name: "\(projectName)/\(repoName)",
            stateRaw: state(status: build.status, result: build.result),
            target: branch,
            url: "",
            createdAt: epochMs(build.queueTime) ?? 0,
            buildingAt: epochMs(build.startTime ?? build.queueTime),
            ready: build.status == "completed" ? epochMs(build.finishTime) : nil,
            creatorUsername: build.requestedFor?.displayName,
            commitOrg: gitHub?.count == 2 ? gitHub?[0] : nil,
            commitRepo: gitHub?.count == 2 ? gitHub?[1] : nil,
            commitSha: build.sourceVersion,
            commitRef: branch,
            commitMessage: build.triggerInfo?["ci.message"] ?? fallbackTitle,
            webURL: build.links?.web.flatMap { URL(string: $0.href) },
            commitURL: build.repository?.type == "TfsGit"
                ? commitURL(organization: organization, project: projectName, repository: repoName,
                            sha: build.sourceVersion)
                : nil
        )
    }

    static func commitURL(organization: String, project: String, repository: String, sha: String?) -> URL? {
        guard let sha, !sha.isEmpty, !project.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dev.azure.com"
        components.path = "/\(organization)/\(project)/_git/\(repository)/commit/\(sha)"
        return components.url
    }

    static func branchName(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    /// ADO run `status`/`result` → the Vercel-shaped tokens `DeploymentState`
    /// understands. `partiallySucceeded` reads as passed, as it does in ADO.
    static func state(status: String?, result: String?) -> String {
        switch status {
        case "inProgress", "cancelling":  return "BUILDING"
        case "notStarted", "postponed":   return "QUEUED"
        case "completed":
            switch result {
            case "succeeded", "partiallySucceeded": return "READY"
            case "failed":                          return "ERROR"
            case "canceled":                        return "CANCELED"
            default:                                return "UNKNOWN"
            }
        default: return "UNKNOWN"
        }
    }

    private static let iso = ISO8601DateFormatter()

    /// ADO timestamps carry up to seven fraction digits, which
    /// `ISO8601DateFormatter` does not reliably parse: the fraction is split
    /// off and added back. Epoch milliseconds, like the other providers.
    static func epochMs(_ raw: String?) -> Double? {
        guard var text = raw else { return nil }
        var fraction = 0.0
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            fraction = Double("0" + text[dot..<end]) ?? 0
            text.removeSubrange(dot..<end)
        }
        guard let date = iso.date(from: text) else { return nil }
        return (date.timeIntervalSince1970 + fraction) * 1000
    }
}

extension AzureDevOpsClient: DeploymentProviderClient {}
