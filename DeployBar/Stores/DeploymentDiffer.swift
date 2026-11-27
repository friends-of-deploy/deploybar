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
            result.append(StateTransition(uid: dep.uid, project: dep.name, key: dep.key,
                                          event: event, destinationURL: dep.destinationURL,
                                          siteURL: dep.siteURL))
        }
        return result
    }

    /// The baseline for the next diff: this tick's rows, plus earlier rows missing
    /// from it. A row can drop out for a tick and still exist (a repo's runs failed
    /// to load); forgetting it would make its return read as a new deployment.
    static func baseline(previous: [DeploymentSnapshot]?,
                         current: [DeploymentSnapshot]) -> [DeploymentSnapshot] {
        guard let previous else { return current }
        let seen = Set(current.map(\.uid))
        // shortcut: a row missing for more than `maxRememberedMissing` newer misses is forgotten
        // and could notify once if it returns; raise the cap if busy accounts report that.
        return current + previous.filter { !seen.contains($0.uid) }.prefix(maxRememberedMissing)
    }

    /// Missing rows kept in the baseline, newest-missing first. Bounds a long-running
    /// session, where every run eventually ages out of the providers' listings.
    static let maxRememberedMissing = 2000

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
