import Foundation

/// Azure DevOps wraps every list in `{ "count": n, "value": [...] }`.
struct ADOList<T: Decodable>: Decodable {
    let value: [T]
}

struct ADOProjectRef: Decodable, Sendable {
    let id: String
    let name: String
}

struct ADOProject: Decodable, Sendable {
    let id: String
    let name: String
    let lastUpdateTime: String?
}

struct ADORepository: Decodable, Sendable {
    let id: String
    let name: String
    let project: ADOProjectRef
    let defaultBranch: String?
    let webUrl: String?
    let isDisabled: Bool?
}

struct ADOBuild: Decodable, Sendable {
    struct Definition: Decodable, Sendable { let id: Int; let name: String }
    struct Repository: Decodable, Sendable { let id: String?; let name: String; let type: String? }
    struct IdentityRef: Decodable, Sendable { let displayName: String? }
    struct Links: Decodable, Sendable {
        struct Href: Decodable, Sendable { let href: String }
        let web: Href?
    }

    let id: Int
    let buildNumber: String?
    let status: String?
    let result: String?
    let queueTime: String?
    let startTime: String?
    let finishTime: String?
    let sourceBranch: String?
    let sourceVersion: String?
    let definition: Definition?
    let repository: Repository?
    let requestedFor: IdentityRef?
    let triggerInfo: [String: String]?
    let project: ADOProjectRef?
    let links: Links?

    enum CodingKeys: String, CodingKey {
        case id, buildNumber, status, result, queueTime, startTime, finishTime, sourceBranch
        case sourceVersion, definition, repository, requestedFor, triggerInfo, project
        case links = "_links"
    }
}

struct ADOTimeline: Decodable, Sendable {
    let records: [ADOTimelineRecord]
}

struct ADOTimelineRecord: Decodable, Sendable {
    struct LogRef: Decodable, Sendable { let id: Int }
    struct Issue: Decodable, Sendable { let type: String?; let message: String? }

    let id: String
    let type: String?
    let name: String?
    let result: String?
    let order: Int?
    let log: LogRef?
    let issues: [Issue]?
}

struct ADOConnectionData: Decodable, Sendable {
    struct User: Decodable, Sendable { let providerDisplayName: String? }
    let authenticatedUser: User
}
