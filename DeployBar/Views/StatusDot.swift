import SwiftUI

extension DeploymentState {
    /// The accent color used for status dots and badges.
    var tint: Color {
        switch self {
        case .ready:              return .green
        case .building, .queued:  return .orange
        case .error:              return .red
        case .canceled, .unknown: return .gray
        }
    }
}

/// A small filled circle whose color reflects a `DeploymentState`.
struct StatusDot: View {
    let state: DeploymentState

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 8, height: 8)
    }
}
