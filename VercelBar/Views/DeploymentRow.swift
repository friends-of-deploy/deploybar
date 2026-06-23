import SwiftUI

struct DeploymentRow: View {
    let deployment: Deployment
    /// Brandable favicon host resolved from the deployment's project (the
    /// deployment's own hashed URL has no favicon). See `DeploymentFavicon`.
    let faviconHost: String?
    /// Fetches the build log for a failed deployment and copies a paste-ready
    /// error report to the clipboard. Returns true on success.
    let copyError: (Deployment) async -> Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Status dot + favicon cluster
            HStack(spacing: 6) {
                StatusDot(state: deployment.state)
                FaviconView(host: faviconHost)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(deployment.name)
                    .font(.body)
                    .fontWeight(.semibold)
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

            Spacer()

            actions
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering = $0 }
        .onTapGesture { openPrimary() }
        .pointingHandCursor()
    }

    // MARK: - Primary row action (ready → open site, failed → open logs)

    /// The URL opened when the row body (not an action icon) is clicked.
    /// Failed deployments open their build logs; everything else opens the live site.
    private var primaryURL: URL? {
        DeploymentRow.primaryDestination(for: deployment)
    }

    private var primaryHelp: String {
        deployment.state == .error ? "Open build logs" : "Open deployment"
    }

    private func openPrimary() {
        if let url = primaryURL { NSWorkspace.shared.open(url) }
    }

    /// Pure rule for the row's default click target.
    static func primaryDestination(for d: Deployment) -> URL? {
        if d.state == .error {
            return d.inspectorUrl.flatMap(URL.init(string:))
                ?? LinkBuilder.liveURL(host: d.url)   // fall back to site if no logs URL
        }
        return LinkBuilder.liveURL(host: d.url)
            ?? d.inspectorUrl.flatMap(URL.init(string:))
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
        let started = "started \(DeploymentTiming.relative(epochMs: deployment.createdAt))"
        return "\(started) · \(DeploymentTiming.buildPhase(deployment))"
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            if deployment.state == .error {
                CopyBuildErrorButton(deployment: deployment, copyError: copyError)
            }
            if let live = LinkBuilder.liveURL(host: deployment.url) {
                IconActionButton(
                    systemImage: "arrow.up.forward.app",
                    url: live,
                    help: "Open deployment"
                )
            }
            if let logs = deployment.inspectorUrl.flatMap(URL.init(string:)) {
                IconActionButton(
                    systemImage: "doc.text.magnifyingglass",
                    url: logs,
                    help: "Open build logs"
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
                    help: "Open commit on the repository"
                )
            }
        }
        .foregroundStyle(.secondary)
        .imageScale(.medium)
    }
}

/// Formats deployment timestamps (epoch milliseconds) for the row's timing line.
enum DeploymentTiming {
    /// "3m ago", "2h ago", "just now" — relative to now.
    static func relative(epochMs: Double) -> String {
        let date = Date(timeIntervalSince1970: epochMs / 1000)
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// "built in 56s" when finished, "building…" when in progress, or "" if unknown.
    static func buildPhase(_ d: Deployment) -> String {
        switch d.state {
        case .building, .queued:
            return "building…"
        case .ready, .error, .canceled, .unknown:
            if let building = d.buildingAt, let ready = d.ready, ready > building {
                return "built in \(duration(seconds: (ready - building) / 1000))"
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
