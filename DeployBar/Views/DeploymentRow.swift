import SwiftUI

struct DeploymentRow: View {
    let deployment: Deployment
    /// Brandable favicon host resolved from the deployment's project (the
    /// deployment's own hashed URL has no favicon). See `DeploymentFavicon`.
    let faviconHost: String?
    /// Direct icon URL fallback (e.g. a GitHub owner avatar) when the project
    /// has no production domain to derive a favicon from.
    var faviconDirectURL: String? = nil
    /// Fetches the build log for a failed deployment and copies a paste-ready
    /// error report to the clipboard. Returns true on success.
    let copyError: (Deployment) async -> Bool
    /// Account/team this row came from. Set only in the "All sources" view, where
    /// one list mixes scopes and two teams may share a project name.
    var scopeLabel: String? = nil
    /// Palette slot for `scopeLabel`'s marker dot, resolved by the store so a
    /// user override in Settings wins over the derived color.
    var scopeColorIndex: Int = 0
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            projectIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(deployment.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let scopeLabel {
                        ScopeDot(label: scopeLabel, color: ScopeColor.color(at: scopeColorIndex))
                    }
                }
                // The author sits beside the commit and timing lines only — the
                // project name above stays flush with the row's text column —
                // and is centered against both, since it belongs to the commit
                // as a whole rather than to either line.
                HStack(alignment: .center, spacing: 7) {
                    CommitAuthorAvatar(
                        login: deployment.commitAuthorLogin,
                        avatarURL: deployment.commitAuthorAvatarURL,
                        creatorUsername: deployment.creatorUsername
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(timing)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            // Claim the row's slack here rather than via a trailing `Spacer`:
            // a spacer would soak up the width freed by hiding the action
            // icons, leaving the commit message truncated exactly as before.
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        // Clip so hover-revealed icons slide out from the row's edge instead of
        // briefly drawing past it.
        .clipped()
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { self.hovering = hovering }
        }
        .onTapGesture { openPrimary() }
        .pointingHandCursor()
        // `onTapGesture` is a gesture, not a control: it is invisible to Full
        // Keyboard Access and VoiceOver, which would leave the row's PRIMARY
        // action (open site / open logs) reachable only by mouse. The row can't
        // simply become a `Button` — it already contains the hover-revealed
        // action buttons, and nesting controls breaks both focus and hit
        // testing — so the row advertises the action itself while leaving its
        // child buttons as their own elements (`.contain`, not `.combine`,
        // which would swallow them).
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(primaryHelp)
        .accessibilityAction { openPrimary() }
    }

    /// Spoken description of the row: project, state, and the commit/timing
    /// context a sighted user reads off the two subtitle lines.
    private var accessibilityLabel: String {
        var parts = [deployment.name, deployment.state.label]
        if let scopeLabel { parts.append(scopeLabel) }
        parts.append(subtitle)
        parts.append(timing)
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Project icon (favicon + status badge)

    private var projectIcon: some View {
        SourceIcon(state: deployment.state, host: faviconHost, directURL: faviconDirectURL)
    }

    // MARK: - Primary row action (ready → open site, failed → open logs)

    /// The URL opened when the row body (not an action icon) is clicked.
    /// Failed deployments open their build logs; everything else opens the live site.
    private var primaryURL: URL? {
        DeploymentRow.primaryDestination(for: deployment)
    }

    private var primaryHelp: String {
        deployment.state == .error
            ? String(localized: "Open build logs", comment: "Action tooltip")
            : String(localized: "Open deployment", comment: "Action tooltip")
    }

    private func openPrimary() {
        if let url = primaryURL { NSWorkspace.shared.open(url) }
    }

    /// Pure rule for the row's default click target.
    static func primaryDestination(for d: Deployment) -> URL? {
        LinkBuilder.deploymentDestination(for: d)
    }

    // MARK: - Subtitle

    private var subtitle: String {
        let msg = deployment.commitMessage?
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? deployment.url
        let ref = deployment.commitRef.map { " · \($0)" } ?? ""
        return "\(msg)\(ref)"
    }

    // MARK: - Timing line (started + build duration)

    private var timing: String {
        let when = DeploymentTiming.relative(epochMs: deployment.createdAt)
        let started = String(localized: "started \(when)", comment: "When a deployment started, e.g. 'started 3m ago'")
        return "\(started) · \(DeploymentTiming.buildPhase(deployment))"
    }

    // MARK: - Actions

    /// One icon is always visible; the rest appear on hover.
    ///
    /// At 380pt the full five-icon cluster claimed ~100pt that the commit
    /// message needed more.
    ///
    /// Order matters: the anchored icon is pinned at the trailing edge and the
    /// hover-revealed ones open to its *left*, into space the subtitle gives
    /// up. Putting the anchored icon first instead would shove it sideways the
    /// instant you hover it, sliding a different action under a cursor that is
    /// already aiming to click — so the row would reliably open the wrong thing.
    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            if hovering {
                secondaryActions
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
            primaryAction
        }
        .foregroundStyle(.secondary)
        .imageScale(.medium)
    }

    /// The most useful action for this row's state: a failed build wants its
    /// error on the clipboard, anything else wants to be opened.
    @ViewBuilder private var primaryAction: some View {
        if deployment.state == .error {
            CopyBuildErrorButton(deployment: deployment, copyError: copyError)
        } else if let open = openURL {
            IconActionButton(
                systemImage: "arrow.up.forward.app",
                url: open,
                help: String(localized: "Open deployment", comment: "Action tooltip")
            )
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        // Shown on hover only. The "open" icon moves here for failed builds,
        // where the clipboard action takes the anchored slot instead.
        if deployment.state == .error, let open = openURL {
            IconActionButton(
                systemImage: "arrow.up.forward.app",
                url: open,
                help: String(localized: "Open deployment", comment: "Action tooltip")
            )
        }
        if let logs = deployment.inspectorUrl.flatMap(URL.init(string:)) {
            IconActionButton(
                systemImage: "doc.text.magnifyingglass",
                url: logs,
                help: String(localized: "Open build logs", comment: "Action tooltip")
            )
        }
        // GitHub runs (webURL set): a shortcut to the repo's Actions overview.
        if deployment.webURL != nil,
           let actions = LinkBuilder.githubActions(org: deployment.commitOrg, repo: deployment.commitRepo) {
            IconActionButton(
                systemImage: "bolt.fill",
                url: actions,
                help: String(localized: "Open Actions", comment: "Action tooltip")
            )
        }
        if let commit = LinkBuilder.githubCommit(
            org: deployment.commitOrg,
            repo: deployment.commitRepo,
            sha: deployment.commitSha
        ) {
            IconActionButton(
                systemImage: "chevron.left.forwardslash.chevron.right",
                url: commit,
                help: String(localized: "Open commit on the repository", comment: "Action tooltip")
            )
        }
    }

    /// Canonical "open the thing" target: a provider page when there is one,
    /// else the live site.
    private var openURL: URL? {
        deployment.webURL ?? LinkBuilder.liveURL(host: deployment.url)
    }
}

/// Formats deployment timestamps (epoch milliseconds) for the row's timing line.
enum DeploymentTiming {
    /// "3m ago", "2h ago", "just now" — relative to now.
    static func relative(epochMs: Double) -> String {
        let date = Date(timeIntervalSince1970: epochMs / 1000)
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return String(localized: "just now", comment: "Relative time, under a minute ago") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// "built in 56s" when finished, "building…" when in progress, or "" if unknown.
    static func buildPhase(_ d: Deployment) -> String {
        switch d.state {
        case .building, .queued:
            return String(localized: "building…", comment: "Build in progress")
        case .ready, .error, .canceled, .unknown:
            if let building = d.buildingAt, let ready = d.ready, ready > building {
                let dur = duration(seconds: (ready - building) / 1000)
                return String(localized: "built in \(dur)", comment: "Completed build duration, e.g. 'built in 56s'")
            }
            return ""
        }
    }

    static func duration(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let rem = s % 60
        return rem == 0 ? "\(m)m" : "\(m)m \(rem)s"
    }
}
