import Foundation

/// Minimal `Decodable` shapes for the subset of the GitHub REST API DeployBar
/// consumes. Kept internal to the GitHub client; they are mapped onto the shared
/// `Project`/`Deployment` models before leaving `GitHubClient`.

struct GHOwner: Decodable, Sendable {
    let login: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

struct GHRepo: Decodable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let owner: GHOwner
    let htmlURL: String
    let defaultBranch: String?
    let homepage: String?
    let language: String?
    let stargazersCount: Int?
    let openIssuesCount: Int?
    let isPrivate: Bool?
    let pushedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, owner, homepage, language
        case fullName = "full_name"
        case htmlURL = "html_url"
        case defaultBranch = "default_branch"
        case stargazersCount = "stargazers_count"
        case openIssuesCount = "open_issues_count"
        case isPrivate = "private"
        case pushedAt = "pushed_at"
    }
}

struct GHRunsResponse: Decodable, Sendable {
    let workflowRuns: [GHRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

struct GHCommit: Decodable, Sendable {
    let message: String?
}

struct GHJobsResponse: Decodable, Sendable {
    let jobs: [GHJob]
}

struct GHJob: Decodable, Sendable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    let htmlURL: String?
    let steps: [GHStep]?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case htmlURL = "html_url"
    }
}

struct GHStep: Decodable, Sendable {
    let name: String
    let status: String?
    let conclusion: String?
    let number: Int?
}

struct GHRun: Decodable, Sendable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let headBranch: String?
    let headSHA: String?
    let status: String?
    let conclusion: String?
    let htmlURL: String
    let createdAt: String
    let updatedAt: String?
    let runStartedAt: String?
    let actor: GHOwner?
    let headCommit: GHCommit?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, actor
        case displayTitle = "display_title"
        case headBranch = "head_branch"
        case headSHA = "head_sha"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case runStartedAt = "run_started_at"
        case headCommit = "head_commit"
    }
}
