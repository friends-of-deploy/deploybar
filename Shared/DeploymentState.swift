import Foundation

/// Shared with the widget extension, which maps snapshot states the same way.
enum DeploymentState: String, Sendable {
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

    /// Not finished on the provider yet, so its row is still worth re-reading.
    /// Only `.building` lights the menu bar icon; see `DeploymentStore.baseState`.
    var isInProgress: Bool { self == .building || self == .queued }

    /// Human-readable, localized label for badges and status text.
    var label: String {
        switch self {
        // A key, not "Done": the bare word is the changelog close button, whose Polish differs.
        case .ready:    return String(localized: "state.done", defaultValue: "Done", comment: "Deployment state badge")
        case .building: return String(localized: "Building", comment: "Deployment state badge")
        case .queued:   return String(localized: "Queued", comment: "Deployment state badge")
        case .error:    return String(localized: "Error", comment: "Deployment state badge")
        case .canceled: return String(localized: "Canceled", comment: "Deployment state badge")
        case .unknown:  return "—"
        }
    }
}
