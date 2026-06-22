import SwiftUI

/// A small filled circle whose color reflects a `DeploymentState`.
struct StatusDot: View {
    let state: DeploymentState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .ready:              return .green
        case .building, .queued:  return .orange
        case .error:              return .red
        case .canceled, .unknown: return .gray
        }
    }
}
