import SwiftUI
import AppKit

/// Custom hover tooltips for the popover.
///
/// Replaces the AppKit `toolTip` this file used to install. That tooltip was
/// both slow (AppKit's ~1-2s dwell is not tunable) and unreliable inside the
/// panel `MenuBarExtra(.window)` hosts content in. These are drawn by SwiftUI
/// in an overlay, so they appear on our own delay, animate in and out, and are
/// styled like the rest of the popover.
///
/// Presentation is centralized in `TooltipHost`, which the popover installs
/// once at its root: a tooltip anchored inside a row would be clipped by that
/// row's bounds (rows use `.clipped()` to contain their hover icons) and could
/// not overhang a neighbor. Each hover target instead publishes its content and
/// screen rect through a preference, and the single host draws it on top.
///
/// See `TooltipContent` for what a target can show — a plain line, or a build
/// state with its status dot.

// MARK: - Content

/// What a tooltip displays. Action icons and the commit author use `.text`; the
/// status badge uses `.status`, which draws the state's dot alongside its name.
enum TooltipContent: Equatable {
    case text(String)
    /// The build state, shown with its colored dot. Deliberately just the
    /// state's name: the branch, sha, author and timing it used to list are all
    /// already on the row itself, so the card only repeated what was on screen.
    case status(DeploymentState)

    /// Plain-text form, used for the accessibility label in every case.
    var accessibilityText: String {
        switch self {
        case .text(let s):     return s
        case .status(let s):   return s.label
        }
    }
}

// MARK: - Public API

extension View {
    /// Shows `message` as a custom tooltip after a short hover delay.
    func tooltip(_ message: String) -> some View {
        modifier(TooltipTrigger(content: .text(message)))
    }

    /// Shows the build state, with its status dot, on hover.
    func statusTooltip(_ state: DeploymentState) -> some View {
        modifier(TooltipTrigger(content: .status(state)))
    }
}

// MARK: - Trigger

/// Publishes this view's tooltip and its frame while the pointer is inside it.
///
/// The delay is applied here rather than in the host so that moving between two
/// targets cancels the pending one cleanly.
private struct TooltipTrigger: ViewModifier {
    let content: TooltipContent

    /// Set only once the dwell delay elapses, so sweeping the pointer across a
    /// row of icons doesn't flash a tooltip per icon.
    @State private var armed = false
    /// Bumped on every hover change so a dwell that is already in flight can
    /// tell it has been superseded. Without it, leaving and re-entering inside
    /// the dwell window leaves the first timer running, and it fires against
    /// the *second* hover — arming the tooltip early.
    @State private var generation = 0

    func body(content body: Content) -> some View {
        body
            .onHover { inside in
                generation &+= 1
                let current = generation
                guard inside else {
                    armed = false
                    return
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(TooltipMetrics.dwell))
                    // Only the newest hover may arm; anything older has been
                    // cancelled by a later enter or leave.
                    if current == generation { armed = true }
                }
            }
            .onDisappear {
                // A row can be scrolled away while hovered; without this its
                // tooltip would outlive it.
                generation &+= 1
                armed = false
            }
            .anchorPreference(key: TooltipPreferenceKey.self, value: .bounds) { anchor in
                armed ? TooltipRequest(content: content, anchor: anchor) : nil
            }
            .accessibilityHint(Text(content.accessibilityText))
    }
}

// MARK: - Preference plumbing

struct TooltipRequest: Equatable {
    let content: TooltipContent
    let anchor: Anchor<CGRect>
}

private struct TooltipPreferenceKey: PreferenceKey {
    static var defaultValue: TooltipRequest? { nil }

    static func reduce(value: inout TooltipRequest?, nextValue: () -> TooltipRequest?) {
        // Last writer wins: with nested targets (an icon inside a hovered row)
        // the innermost view publishes later, and it is the more specific one.
        if let next = nextValue() { value = next }
    }
}

// MARK: - Host

extension View {
    /// Draws whichever tooltip is currently armed. Install once, at the root of
    /// the popover — see the note at the top of this file.
    func tooltipHost() -> some View {
        modifier(TooltipHost())
    }
}

private struct TooltipHost: ViewModifier {
    @State private var request: TooltipRequest?

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(TooltipPreferenceKey.self) { request in
                GeometryReader { proxy in
                    if let request {
                        TooltipBubble(content: request.content)
                            .modifier(TooltipPlacement(rect: proxy[request.anchor],
                                                       container: proxy.size))
                    }
                }
                // The bubble must never eat a click meant for the icon it
                // describes, nor re-trigger hover tracking underneath itself.
                .allowsHitTesting(false)
                .animation(TooltipMetrics.transition, value: request)
            }
    }
}

/// Positions the bubble above its target, flipping below when there is no room,
/// and keeps it inside the popover's width.
private struct TooltipPlacement: ViewModifier {
    let rect: CGRect
    let container: CGSize

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .modifier(TooltipOffset(rect: rect, container: container))
            // A short lift into place. The scale was dropped with the spring:
            // together they made the bubble look like it was popping open,
            // which is a lot of motion for a label.
            .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

/// Measures the bubble, then places it — the offset depends on its own size, so
/// this has to happen after layout rather than in the parent.
private struct TooltipOffset: ViewModifier {
    let rect: CGRect
    let container: CGSize

    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, new in size = new }
                }
            )
            .offset(x: x, y: y)
            // Until measured, keep it invisible rather than letting it paint one
            // frame at the wrong place.
            .opacity(size == .zero ? 0 : 1)
    }

    private var x: CGFloat {
        TooltipPlacementMath.x(targetMidX: rect.midX,
                               bubbleWidth: size.width,
                               containerWidth: container.width)
    }

    private var y: CGFloat {
        TooltipPlacementMath.y(targetMinY: rect.minY,
                               targetMaxY: rect.maxY,
                               bubbleHeight: size.height)
    }
}

// MARK: - Bubble

private struct TooltipBubble: View {
    let content: TooltipContent

    var body: some View {
        Group {
            switch content {
            case .text(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    // A tooltip that wrapped to the popover's full width would
                    // read as a paragraph; these are labels.
                    .frame(maxWidth: TooltipMetrics.maxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            case .status(let state):
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.tint)
                        .frame(width: 6, height: 6)
                    Text(state.label)
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
    }
}

// MARK: - Shared metrics

/// One place for the tooltip's timing and spacing, so every tooltip in the
/// popover behaves identically.
enum TooltipMetrics {
    /// Hover dwell before a tooltip appears. Well under AppKit's, which is what
    /// made the system tooltips impractical here, but long enough that crossing
    /// the icon cluster on the way elsewhere stays quiet.
    static let dwell = 160

    /// Appearance/disappearance. `easeOut` rather than a spring: a spring's
    /// settle reads as bounce on something this small, and the tooltip should
    /// simply be *there* the moment the dwell ends.
    static let transition = Animation.easeOut(duration: 0.11)

    static let maxWidth: CGFloat = 260
    /// Distance between the bubble and the view it describes.
    static let gap: CGFloat = 6
    /// Minimum distance from the popover's edges.
    static let margin: CGFloat = 6
}

/// Where a tooltip bubble is drawn, given its target and the popover's bounds.
///
/// Extracted from the view so the placement rules — flip below when there is no
/// room above, never cross the popover's edges — can be checked directly.
enum TooltipPlacementMath {
    /// Centered on the target, clamped so neither edge leaves the container.
    static func x(targetMidX: CGFloat, bubbleWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let ideal = targetMidX - bubbleWidth / 2
        let maxX = max(TooltipMetrics.margin, containerWidth - bubbleWidth - TooltipMetrics.margin)
        return min(max(TooltipMetrics.margin, ideal), maxX)
    }

    /// Above the target by preference; below when it would otherwise be clipped
    /// by the top of the panel.
    static func y(targetMinY: CGFloat, targetMaxY: CGFloat, bubbleHeight: CGFloat) -> CGFloat {
        let above = targetMinY - bubbleHeight - TooltipMetrics.gap
        if above >= TooltipMetrics.margin { return above }
        return targetMaxY + TooltipMetrics.gap
    }
}
