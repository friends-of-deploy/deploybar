import Foundation

enum DeploymentState: String {
    case ready, building, queued, error, canceled, unknown

    init(apiValue: String) {
        switch apiValue.uppercased() {
        case "READY": self = .ready
        case "BUILDING", "INITIALIZING": self = .building
        case "QUEUED": self = .queued
        case "ERROR": self = .error
        case "CANCELED": self = .canceled
        default: self = .unknown
        }
    }

    /// Human-readable, localized label for badges and status text.
    var label: String {
        switch self {
        case .ready:    return String(localized: "Ready", comment: "Deployment state badge")
        case .building: return String(localized: "Building", comment: "Deployment state badge")
        case .queued:   return String(localized: "Queued", comment: "Deployment state badge")
        case .error:    return String(localized: "Error", comment: "Deployment state badge")
        case .canceled: return String(localized: "Canceled", comment: "Deployment state badge")
        case .unknown:  return "—"
        }
    }
}

struct DeploymentsResponse: Decodable {
    let deployments: [Deployment]
}

struct Deployment: Decodable, Identifiable {
    let uid: String
    let name: String          // project name
    let stateRaw: String
    let target: String?
    let url: String
    let inspectorUrl: String?
    let createdAt: Double
    let buildingAt: Double?
    let ready: Double?
    let creatorUsername: String?

    // git metadata
    let commitOrg: String?
    let commitRepo: String?
    let commitSha: String?
    let commitRef: String?
    let commitMessage: String?

    /// Provider-supplied canonical web page for this deployment/run. When set it
    /// takes precedence over the Vercel host-based link building in the row.
    /// Vercel leaves this `nil` (its links derive from `url`/`inspectorUrl`);
    /// GitHub sets it to the workflow run's `html_url`.
    let webURL: URL?

    var id: String { uid }
    var state: DeploymentState { DeploymentState(apiValue: stateRaw) }

    enum CodingKeys: String, CodingKey {
        case uid, name, target, url, inspectorUrl, createdAt, buildingAt, ready, creator, meta
        case stateRaw = "state"
    }
    private enum CreatorKeys: String, CodingKey { case username }
    private enum MetaKeys: String, CodingKey {
        case githubCommitOrg, githubCommitRepo, githubCommitSha, githubCommitRef, githubCommitMessage
    }

    /// Memberwise initializer for non-Vercel providers (e.g. `GitHubClient`) that
    /// build a `Deployment` from their own JSON rather than the Vercel decoder.
    init(uid: String, name: String, stateRaw: String, target: String? = nil,
         url: String, inspectorUrl: String? = nil, createdAt: Double,
         buildingAt: Double? = nil, ready: Double? = nil, creatorUsername: String? = nil,
         commitOrg: String? = nil, commitRepo: String? = nil, commitSha: String? = nil,
         commitRef: String? = nil, commitMessage: String? = nil, webURL: URL? = nil) {
        self.uid = uid
        self.name = name
        self.stateRaw = stateRaw
        self.target = target
        self.url = url
        self.inspectorUrl = inspectorUrl
        self.createdAt = createdAt
        self.buildingAt = buildingAt
        self.ready = ready
        self.creatorUsername = creatorUsername
        self.commitOrg = commitOrg
        self.commitRepo = commitRepo
        self.commitSha = commitSha
        self.commitRef = commitRef
        self.commitMessage = commitMessage
        self.webURL = webURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(String.self, forKey: .uid)
        webURL = nil
        name = try c.decode(String.self, forKey: .name)
        stateRaw = try c.decode(String.self, forKey: .stateRaw)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        url = try c.decode(String.self, forKey: .url)
        inspectorUrl = try c.decodeIfPresent(String.self, forKey: .inspectorUrl)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        buildingAt = try c.decodeIfPresent(Double.self, forKey: .buildingAt)
        ready = try c.decodeIfPresent(Double.self, forKey: .ready)

        if let cc = try? c.nestedContainer(keyedBy: CreatorKeys.self, forKey: .creator) {
            creatorUsername = try cc.decodeIfPresent(String.self, forKey: .username)
        } else { creatorUsername = nil }

        if let mc = try? c.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta) {
            commitOrg = try mc.decodeIfPresent(String.self, forKey: .githubCommitOrg)
            commitRepo = try mc.decodeIfPresent(String.self, forKey: .githubCommitRepo)
            commitSha = try mc.decodeIfPresent(String.self, forKey: .githubCommitSha)
            commitRef = try mc.decodeIfPresent(String.self, forKey: .githubCommitRef)
            commitMessage = try mc.decodeIfPresent(String.self, forKey: .githubCommitMessage)
        } else {
            commitOrg = nil; commitRepo = nil; commitSha = nil; commitRef = nil; commitMessage = nil
        }
    }
}
