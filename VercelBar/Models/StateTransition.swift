import Foundation

enum DeploymentEvent: String, Equatable { case started, success, failure, canceled }

struct StateTransition: Equatable {
    let uid: String
    let project: String
    let key: ProjectKey
    let event: DeploymentEvent
}

struct DeploymentSnapshot: Equatable {
    let uid: String
    let name: String
    let state: DeploymentState
    let key: ProjectKey
}

extension DeploymentSnapshot {
    /// Minimal info the differ needs (decoupled from the full Deployment model).
    init(_ d: Deployment, key: ProjectKey) {
        self.init(uid: d.uid, name: d.name, state: d.state, key: key)
    }
}
