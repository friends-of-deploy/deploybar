import Foundation

enum DeploymentDiffer {
    /// Returns transitions worth notifying about. A nil `previous` means first
    /// poll → silent (seed baseline only).
    static func transitions(previous: [DeploymentSnapshot]?,
                            current: [DeploymentSnapshot]) -> [StateTransition] {
        guard let previous else { return [] }
        let prevByUID = Dictionary(previous.map { ($0.uid, $0.state) }) { a, _ in a }

        var result: [StateTransition] = []
        for dep in current {
            let before = prevByUID[dep.uid]
            if before == dep.state { continue }
            guard let event = event(for: dep.state) else { continue }
            result.append(StateTransition(uid: dep.uid, project: dep.name, event: event))
        }
        return result
    }

    private static func event(for state: DeploymentState) -> DeploymentEvent? {
        switch state {
        case .building, .queued: return .started
        case .ready: return .success
        case .error: return .failure
        case .canceled: return .canceled
        case .unknown: return nil
        }
    }
}
