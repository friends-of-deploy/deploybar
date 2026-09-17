import Foundation

/// On-disk snapshot of the last successful poll, so a relaunch paints the rows it
/// showed before instead of an empty list while the network answers.
///
/// `Deployment` and `Project` decode from the *provider's* JSON shape (nested
/// `creator`/`meta` containers, provider-specific keys). Making them `Encodable`
/// would emit a shape their own decoders can't read back, so the cache uses these
/// explicit flat mirrors and rebuilds the models via their memberwise inits.
struct RowCache: Codable {
    var deployments: [CachedDeployment] = []
    var projects: [CachedProject] = []
    /// When the snapshot was taken, to discard one that's too old to be useful.
    var savedAt: Date = .distantPast

    struct CachedDeployment: Codable {
        var accountId: UUID
        var teamId: String?
        var uid: String
        var name: String
        var stateRaw: String
        var target: String?
        var url: String
        var inspectorUrl: String?
        var createdAt: Double
        var buildingAt: Double?
        var ready: Double?
        var creatorUsername: String?
        var commitOrg: String?
        var commitRepo: String?
        var commitSha: String?
        var commitRef: String?
        var commitMessage: String?
        var commitAuthorLogin: String?
        var commitAuthorAvatarURL: String?
        var webURL: URL?

        init(_ sd: SourcedDeployment) {
            let d = sd.deployment
            accountId = sd.account.id
            teamId = sd.teamId
            uid = d.uid
            name = d.name
            stateRaw = d.stateRaw
            target = d.target
            url = d.url
            inspectorUrl = d.inspectorUrl
            createdAt = d.createdAt
            buildingAt = d.buildingAt
            ready = d.ready
            creatorUsername = d.creatorUsername
            commitOrg = d.commitOrg
            commitRepo = d.commitRepo
            commitSha = d.commitSha
            commitRef = d.commitRef
            commitMessage = d.commitMessage
            commitAuthorLogin = d.commitAuthorLogin
            commitAuthorAvatarURL = d.commitAuthorAvatarURL
            webURL = d.webURL
        }

        /// Rebuilds the row, or nil when its account is no longer connected.
        func restore(accounts: [UUID: Account]) -> SourcedDeployment? {
            guard let account = accounts[accountId] else { return nil }
            let deployment = Deployment(
                uid: uid, name: name, stateRaw: stateRaw, target: target, url: url,
                inspectorUrl: inspectorUrl, createdAt: createdAt, buildingAt: buildingAt,
                ready: ready, creatorUsername: creatorUsername, commitOrg: commitOrg,
                commitRepo: commitRepo, commitSha: commitSha, commitRef: commitRef,
                commitMessage: commitMessage, commitAuthorLogin: commitAuthorLogin,
                commitAuthorAvatarURL: commitAuthorAvatarURL, webURL: webURL)
            return SourcedDeployment(deployment: deployment, account: account, teamId: teamId)
        }
    }

    struct CachedProject: Codable {
        var accountId: UUID
        var teamId: String?
        var id: String
        var name: String
        var repoType: String?
        var repoOrg: String?
        var repoName: String?
        var productionBranch: String?
        var productionURL: String?
        var productionAliases: [String]
        var framework: String?
        var nodeVersion: String?
        var envCount: Int
        var cronCount: Int
        var hasAnalytics: Bool
        var latestStateRaw: String?
        var latestCreatedAt: Double?
        var starCount: Int?
        var openIssueCount: Int?
        var isPrivate: Bool?
        var pushedAt: Double?
        var iconURL: String?

        init(_ sp: SourcedProject) {
            let p = sp.project
            accountId = sp.account.id
            teamId = sp.teamId
            id = p.id
            name = p.name
            repoType = p.repoType
            repoOrg = p.repoOrg
            repoName = p.repoName
            productionBranch = p.productionBranch
            productionURL = p.productionURL
            productionAliases = p.productionAliases
            framework = p.framework
            nodeVersion = p.nodeVersion
            envCount = p.envCount
            cronCount = p.cronCount
            hasAnalytics = p.hasAnalytics
            latestStateRaw = p.latestStateRaw
            latestCreatedAt = p.latestCreatedAt
            starCount = p.starCount
            openIssueCount = p.openIssueCount
            isPrivate = p.isPrivate
            pushedAt = p.pushedAt
            iconURL = p.iconURL
        }

        func restore(accounts: [UUID: Account]) -> SourcedProject? {
            guard let account = accounts[accountId] else { return nil }
            let project = Project(
                id: id, name: name, repoType: repoType, repoOrg: repoOrg, repoName: repoName,
                productionBranch: productionBranch, productionURL: productionURL,
                productionAliases: productionAliases, framework: framework,
                nodeVersion: nodeVersion, envCount: envCount, cronCount: cronCount,
                hasAnalytics: hasAnalytics, latestStateRaw: latestStateRaw,
                latestCreatedAt: latestCreatedAt, starCount: starCount,
                openIssueCount: openIssueCount, isPrivate: isPrivate, pushedAt: pushedAt,
                iconURL: iconURL)
            return SourcedProject(project: project, account: account, teamId: teamId)
        }
    }

    init() {}

    init(deployments: [SourcedDeployment], projects: [SourcedProject], savedAt: Date) {
        self.deployments = deployments.map(CachedDeployment.init)
        self.projects = projects.map(CachedProject.init)
        self.savedAt = savedAt
    }
}
