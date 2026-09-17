import SwiftUI

/// A small health indicator beside the scope picker: amber when a source failed
/// to refresh, plain when everything is fine.
///
/// Replaces the bottom status bar, which spent a full row of a 380pt popover on
/// a single line of text that was usually absent — and, when present, was
/// truncated anyway. The issues now live in the dot's tooltip, which can list
/// every failing source instead of just the first.
///
/// Clicking refreshes immediately. `DeploymentStore.poll()` guards its own
/// re-entrancy, so a double-click is harmless.
struct HealthDot: View {
    let issues: [String]
    let isRefreshing: Bool
    let refresh: () -> Void

    @State private var hovering = false

    private var isHealthy: Bool { issues.isEmpty }

    var body: some View {
        Button(action: refresh) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))

                // The glyph never changes while refreshing: it reports the state
                // of the sources, which a spin would overwrite with "busy".
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHealthy ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))

                // Progress is a separate layer that sweeps *around* the glyph.
                SpinnerRing(isSpinning: isRefreshing)
                    .foregroundStyle(isHealthy ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .tooltip(tooltipText)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Hovering an *idle* healthy dot shouldn't imply anything is wrong, so the
    /// glyph only becomes a warning when there is something to warn about.
    private var symbol: String {
        isHealthy ? "checkmark.circle" : "exclamationmark.triangle.fill"
    }

    /// The tooltip carries what the status bar used to: every issue, one per
    /// line, plus the hint that clicking refreshes.
    /// The issues stay listed while refreshing — the spinning ring already says
    /// a refresh is running, so replacing the text with "Refreshing…" would drop
    /// the only copy of what is actually wrong.
    private var tooltipText: String {
        let hint = isRefreshing
            ? String(localized: "Refreshing…", comment: "Health dot tooltip while polling")
            : String(localized: "Click to refresh", comment: "Health dot tooltip hint")
        guard !isHealthy else {
            return String(localized: "All sources up to date\n\(hint)",
                          comment: "Health dot tooltip when there are no issues")
        }
        return (issues + [hint]).joined(separator: "\n")
    }

    /// A ring that sweeps around the health glyph while a refresh is running.
    ///
    /// Drawn as its own layer rather than by spinning the glyph: the icon states
    /// what is wrong with the sources, and rotating it would trade that reading
    /// for "busy" at exactly the moment the user asked about it.
    ///
    /// It appears on refresh and fades out when the poll settles, so an idle dot
    /// stays a dot. The rotation is driven by an `onAppear` state flip rather
    /// than `repeatForever` keyed on `isRefreshing`: a repeating animation bound
    /// to a value can outlive the condition that started it and keep spinning an
    /// invisible view.
    private struct SpinnerRing: View {
        let isSpinning: Bool

        @State private var turning = false
        /// Reduce Motion replaces the rotation with a static ring: the ring's
        /// presence already says "refreshing", so the state stays legible
        /// without anything spinning indefinitely.
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Group {
                if isSpinning {
                    Circle()
                        // A gap in the stroke is what makes the rotation legible;
                        // a closed ring would look identical at every angle.
                        .trim(from: 0, to: 0.7)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(turning ? 360 : 0))
                        .onAppear {
                            guard !reduceMotion else { return }
                            turning = false
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                turning = true
                            }
                        }
                        .onDisappear { turning = false }
                        .transition(reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSpinning)
        }
    }

    private var accessibilityLabel: String {
        guard !isHealthy else {
            return String(localized: "All sources up to date. Refresh.",
                          comment: "Health dot accessibility label, no issues")
        }
        return String(localized: "\(issues.count) source issues. Refresh.",
                      comment: "Health dot accessibility label with issue count")
    }
}
