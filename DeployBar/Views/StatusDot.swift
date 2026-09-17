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
    var size: CGFloat = 8
    /// Draws a ring in the row's background color around the dot. Used when the
    /// dot overlaps an icon, where it needs to read as a separate badge rather
    /// than as part of the artwork underneath.
    var bordered: Bool = false
    @State private var pulsing = false
    /// Reduce Motion turns the indefinite pulse off. The dot keeps its color,
    /// so "building" is still distinguishable — it just doesn't move.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether a state pulses at all, and whether motion is permitted.
    /// Static so the rule is testable without building the view.
    static func shouldPulse(state: DeploymentState, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        return state == .building || state == .queued
    }

    /// Whether the dot should actually animate right now.
    private var shouldPulse: Bool {
        Self.shouldPulse(state: state, reduceMotion: reduceMotion)
    }

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: size, height: size)
            .modifier(StatusDotBorder(enabled: bordered, size: size))
            .opacity(shouldPulse && pulsing ? 0.35 : 1)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            // Color changes (a build going green) ease rather than snap.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
            .onAppear { pulsing = shouldPulse }
            .onChange(of: shouldPulse) { _, pulse in pulsing = pulse }
    }
}

/// Punches a ring out from behind the dot so it separates from whatever it
/// overlaps. Drawn as a stroke in the material background rather than a solid
/// fill: a hard-coded color would be wrong against the popover's translucent
/// material in one of the two appearances.
private struct StatusDotBorder: ViewModifier {
    let enabled: Bool
    let size: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(1.5)
                .background(.background, in: Circle())
        } else {
            content
        }
    }
}
