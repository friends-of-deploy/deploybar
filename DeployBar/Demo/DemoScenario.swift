import Foundation

/// A whole invented world for demo mode, decoded from a bundled JSON fixture.
///
/// Deployment times are *relative* (`ageSeconds`) rather than absolute so a
/// fixture never goes stale: "2m ago" reads the same on every run, months apart.
struct DemoScenario: Codable, Sendable {
    let accounts: [DemoAccount]
    let projects: [DemoProject]
    let deployments: [DemoDeployment]
    let timeline: [DemoTimelineEvent]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decode([DemoAccount].self, forKey: .accounts)
        projects = try c.decode([DemoProject].self, forKey: .projects)
        deployments = try c.decode([DemoDeployment].self, forKey: .deployments)
        timeline = try c.decodeIfPresent([DemoTimelineEvent].self, forKey: .timeline) ?? []
    }
}

enum DemoSourceKind: String, Codable, Sendable {
    case vercelCLI, githubCLI, keychain
}

struct DemoTeam: Codable, Sendable {
    let id: String
    let slug: String
    let name: String
}

struct DemoAccount: Codable, Sendable {
    /// Stable handle that `DemoProject`/`DemoDeployment` reference, so the JSON
    /// needs no UUIDs (those are minted at launch).
    let key: String
    let provider: Provider
    let label: String
    let sourceKind: DemoSourceKind
    let teams: [DemoTeam]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        provider = try c.decode(Provider.self, forKey: .provider)
        label = try c.decode(String.self, forKey: .label)
        sourceKind = try c.decode(DemoSourceKind.self, forKey: .sourceKind)
        teams = try c.decodeIfPresent([DemoTeam].self, forKey: .teams) ?? []
    }
}

struct DemoProject: Codable, Sendable {
    let accountKey: String
    let teamId: String?
    let id: String
    let name: String
    let repoOrg: String?
    let repoName: String?
    let productionURL: String?
    let framework: String?
    let latestState: String?
    let starCount: Int?
    let openIssueCount: Int?
    let followed: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try c.decode(String.self, forKey: .accountKey)
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        repoOrg = try c.decodeIfPresent(String.self, forKey: .repoOrg)
        repoName = try c.decodeIfPresent(String.self, forKey: .repoName)
        productionURL = try c.decodeIfPresent(String.self, forKey: .productionURL)
        framework = try c.decodeIfPresent(String.self, forKey: .framework)
        latestState = try c.decodeIfPresent(String.self, forKey: .latestState)
        starCount = try c.decodeIfPresent(Int.self, forKey: .starCount)
        openIssueCount = try c.decodeIfPresent(Int.self, forKey: .openIssueCount)
        followed = try c.decodeIfPresent(Bool.self, forKey: .followed) ?? true
    }
}

struct DemoDeployment: Codable, Sendable {
    let accountKey: String
    let teamId: String?
    let uid: String
    let projectName: String
    let state: String
    /// Seconds before demo "now". The client converts this to an absolute
    /// `createdAt` at read time.
    let ageSeconds: Double
    let url: String
    let commitOrg: String?
    let commitRepo: String?
    let commitSha: String?
    let commitRef: String?
    let commitMessage: String?
    let commitAuthorLogin: String?
    let creatorUsername: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try c.decode(String.self, forKey: .accountKey)
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId)
        uid = try c.decode(String.self, forKey: .uid)
        projectName = try c.decode(String.self, forKey: .projectName)
        state = try c.decode(String.self, forKey: .state)
        ageSeconds = try c.decode(Double.self, forKey: .ageSeconds)
        url = try c.decode(String.self, forKey: .url)
        commitOrg = try c.decodeIfPresent(String.self, forKey: .commitOrg)
        commitRepo = try c.decodeIfPresent(String.self, forKey: .commitRepo)
        commitSha = try c.decodeIfPresent(String.self, forKey: .commitSha)
        commitRef = try c.decodeIfPresent(String.self, forKey: .commitRef)
        commitMessage = try c.decodeIfPresent(String.self, forKey: .commitMessage)
        commitAuthorLogin = try c.decodeIfPresent(String.self, forKey: .commitAuthorLogin)
        creatorUsername = try c.decodeIfPresent(String.self, forKey: .creatorUsername)
    }
}

/// A scheduled state change, driving the live simulation.
struct DemoTimelineEvent: Codable, Sendable {
    let atSeconds: Double
    let deploymentUid: String
    let newState: String
}
