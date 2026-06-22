import Foundation

enum DeploymentEvent: String, Equatable { case started, success, failure, canceled }

struct StateTransition: Equatable {
    let uid: String
    let project: String
    let event: DeploymentEvent
}

struct DeploymentSnapshot: Equatable {
    let uid: String
    let name: String
    let state: DeploymentState
}

extension DeploymentSnapshot {
    /// Minimal info the differ needs (decoupled from the full Deployment model).
    init(_ d: Deployment) { self.init(uid: d.uid, name: d.name, state: d.state) }
}
