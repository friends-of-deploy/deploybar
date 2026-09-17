import Foundation

struct ProjectsResponse: Decodable, Sendable {
    let projects: [Project]
    let pagination: ProjectsPagination?
}

/// Vercel paginates `/v9/projects` at 100 per page. `next` is a cursor (a
/// timestamp) to pass back as `until` for the next page; it's nil on the last page.
struct ProjectsPagination: Decodable, Sendable {
    let next: Double?
}

struct Project: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let repoType: String?     // "github"
    let repoOrg: String?
    let repoName: String?
    let productionBranch: String?
    let productionURL: String?
    let productionAliases: [String]
    let framework: String?
    let nodeVersion: String?
    let envCount: Int
    let cronCount: Int
    let hasAnalytics: Bool
    let latestStateRaw: String?
    let latestCreatedAt: Double?
    // Repository stats (GitHub sources only; nil for Vercel projects).
    let starCount: Int?
    let openIssueCount: Int?
    let isPrivate: Bool?
    let pushedAt: Double?
    /// Direct icon URL (e.g. a GitHub owner avatar), used when there is no
    /// production domain to derive a favicon from.
    let iconURL: String?

    var latestState: DeploymentState {
        latestStateRaw.map { DeploymentState(apiValue: $0) } ?? .unknown
    }

    /// Memberwise initializer for non-Vercel providers (e.g. `GitHubClient`) that
    /// build a `Project` from their own JSON rather than the Vercel decoder.
    init(id: String, name: String, repoType: String? = nil, repoOrg: String? = nil,
         repoName: String? = nil, productionBranch: String? = nil,
         productionURL: String? = nil, productionAliases: [String] = [],
         framework: String? = nil, nodeVersion: String? = nil,
         envCount: Int = 0, cronCount: Int = 0, hasAnalytics: Bool = false,
         latestStateRaw: String? = nil, latestCreatedAt: Double? = nil,
         starCount: Int? = nil, openIssueCount: Int? = nil, isPrivate: Bool? = nil,
         pushedAt: Double? = nil, iconURL: String? = nil) {
        self.id = id
        self.name = name
        self.repoType = repoType
        self.repoOrg = repoOrg
        self.repoName = repoName
        self.productionBranch = productionBranch
        self.productionURL = productionURL
        self.productionAliases = productionAliases
        self.framework = framework
        self.nodeVersion = nodeVersion
        self.envCount = envCount
        self.cronCount = cronCount
        self.hasAnalytics = hasAnalytics
        self.latestStateRaw = latestStateRaw
        self.latestCreatedAt = latestCreatedAt
        self.starCount = starCount
        self.openIssueCount = openIssueCount
        self.isPrivate = isPrivate
        self.pushedAt = pushedAt
        self.iconURL = iconURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, link, latestDeployments, targets, framework, nodeVersion, env, crons, webAnalytics
    }
    private enum LinkKeys: String, CodingKey { case type, org, repo, productionBranch }
    private enum LatestKeys: String, CodingKey { case readyState, createdAt }
    private enum TargetKeys: String, CodingKey { case production }
    private enum TargetURLKeys: String, CodingKey { case url, alias }
    private enum CronsKeys: String, CodingKey { case definitions }
    private enum AnalyticsKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        framework = try c.decodeIfPresent(String.self, forKey: .framework)
        nodeVersion = try c.decodeIfPresent(String.self, forKey: .nodeVersion)

        // env is an array of variables; we only surface its count.
        if let env = try? c.nestedUnkeyedContainer(forKey: .env) {
            envCount = env.count ?? 0
        } else { envCount = 0 }

        // crons.definitions is an array; surface its count (0 when absent).
        if let cc = try? c.nestedContainer(keyedBy: CronsKeys.self, forKey: .crons),
           let defs = try? cc.nestedUnkeyedContainer(forKey: .definitions) {
            cronCount = defs.count ?? 0
        } else { cronCount = 0 }

        // webAnalytics has a non-null id when analytics is enabled.
        if let ac = try? c.nestedContainer(keyedBy: AnalyticsKeys.self, forKey: .webAnalytics) {
            let analyticsId = try? ac.decodeIfPresent(String.self, forKey: .id)
            hasAnalytics = (analyticsId ?? nil) != nil
        } else { hasAnalytics = false }

        if let lc = try? c.nestedContainer(keyedBy: LinkKeys.self, forKey: .link) {
            repoType = try lc.decodeIfPresent(String.self, forKey: .type)
            repoOrg = try lc.decodeIfPresent(String.self, forKey: .org)
            repoName = try lc.decodeIfPresent(String.self, forKey: .repo)
            productionBranch = try lc.decodeIfPresent(String.self, forKey: .productionBranch)
        } else { repoType = nil; repoOrg = nil; repoName = nil; productionBranch = nil }

        var latestStateRaw: String? = nil
        var latestCreatedAt: Double? = nil
        if var arr = try? c.nestedUnkeyedContainer(forKey: .latestDeployments),
           !arr.isAtEnd, let first = try? arr.nestedContainer(keyedBy: LatestKeys.self) {
            latestStateRaw = try first.decodeIfPresent(String.self, forKey: .readyState)
            latestCreatedAt = try first.decodeIfPresent(Double.self, forKey: .createdAt)
        }
        self.latestStateRaw = latestStateRaw
        self.latestCreatedAt = latestCreatedAt

        if let tc = try? c.nestedContainer(keyedBy: TargetKeys.self, forKey: .targets),
           let pc = try? tc.nestedContainer(keyedBy: TargetURLKeys.self, forKey: .production) {
            productionURL = try pc.decodeIfPresent(String.self, forKey: .url)
            productionAliases = (try? pc.decodeIfPresent([String].self, forKey: .alias)) ?? []
        } else { productionURL = nil; productionAliases = [] }

        // Repo stats / icon are GitHub-only.
        starCount = nil; openIssueCount = nil; isPrivate = nil; pushedAt = nil; iconURL = nil
    }

    /// The best host for fetching a favicon / opening the live site: prefers a
    /// custom domain from the production aliases, then a clean `<project>.vercel.app`,
    /// then the generated production URL.
    var faviconHost: String? {
        BestDomain.pick(url: productionURL, aliases: productionAliases)
    }
}

/// Picks the most "brandable" host from a project's production url + aliases.
/// Custom domains (not *.vercel.app) win; otherwise a clean project alias beats
/// the generated deployment URL (which has a random hash and no favicon).
enum BestDomain {
    static func pick(url: String?, aliases: [String]) -> String? {
        let all = aliases + [url].compactMap { $0 }
        let cleaned = all.filter { !$0.isEmpty }

        // 1. Custom domain (does not end in vercel.app).
        if let custom = cleaned.first(where: { !$0.hasSuffix(".vercel.app") }) {
            return custom
        }
        // 2. A clean *.vercel.app alias without a git-branch or deployment-hash segment.
        //    Prefer the shortest (e.g. "myapp-acme.vercel.app" over
        //    "myapp-git-main-acme.vercel.app").
        let vercelAliases = cleaned
            .filter { $0.hasSuffix(".vercel.app") && !$0.contains("-git-") }
            .sorted { $0.count < $1.count }
        if let best = vercelAliases.first { return best }
        // 3. Fall back to whatever we have.
        return cleaned.first
    }
}
