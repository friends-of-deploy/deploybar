import SwiftUI

/// A small tinted capsule showing a deployment's state (Ready / Building / …).
/// Colors track `DeploymentState.tint` so the badge stays in sync with `StatusDot`.
struct StateBadge: View {
    let state: DeploymentState

    var body: some View {
        Text(state.label)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(state.tint.opacity(0.15), in: Capsule())
    }
}
