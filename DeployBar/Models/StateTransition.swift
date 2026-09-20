import Foundation

enum DeploymentEvent: String, Equatable { case started, success, failure, canceled }

struct StateTransition: Equatable {
    let uid: String
    let project: String
    let key: ProjectKey
    let event: DeploymentEvent
    let destinationURL: URL?
    let siteURL: URL?

    init(uid: String, project: String, key: ProjectKey, event: DeploymentEvent,
         destinationURL: URL? = nil, siteURL: URL? = nil) {
        self.uid = uid
        self.project = project
        self.key = key
        self.event = event
        self.destinationURL = destinationURL
        self.siteURL = siteURL
    }
}

struct DeploymentSnapshot: Equatable {
    let uid: String
    let name: String
    let state: DeploymentState
    let key: ProjectKey
    let destinationURL: URL?
    let siteURL: URL?

    init(uid: String, name: String, state: DeploymentState, key: ProjectKey,
         destinationURL: URL? = nil, siteURL: URL? = nil) {
        self.uid = uid
        self.name = name
        self.state = state
        self.key = key
        self.destinationURL = destinationURL
        self.siteURL = siteURL
    }
}

extension DeploymentSnapshot {
    /// Minimal info the differ needs (decoupled from the full Deployment model).
    init(_ d: Deployment, key: ProjectKey) {
        self.init(uid: d.uid, name: d.name, state: d.state, key: key,
                  destinationURL: d.webURL ?? d.inspectorUrl.flatMap(URL.init(string:))
                    ?? LinkBuilder.liveURL(host: d.url),
                  siteURL: LinkBuilder.liveURL(host: d.url))
    }
}
