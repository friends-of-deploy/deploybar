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
///
/// In-flight states (building/queued) pulse, so "running right now" reads at a
/// glance instead of requiring the timing line to distinguish it from a build
/// that finished and stayed orange.
struct StatusDot: View {
    let state: DeploymentState
    @State private var pulsing = false

    private var isInFlight: Bool {
        state == .building || state == .queued
    }

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 8, height: 8)
            .opacity(isInFlight && pulsing ? 0.35 : 1)
            .animation(
                isInFlight
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            // Color changes (a build going green) ease rather than snap.
            .animation(.easeInOut(duration: 0.25), value: state)
            .onAppear { pulsing = isInFlight }
            .onChange(of: isInFlight) { _, inFlight in pulsing = inFlight }
    }
}
