import SwiftUI

struct ProjectRow: View {
    let project: Project
    let scopeName: String
    /// The source provider, used to gate provider-specific actions (the Vercel
    /// dashboard deep links don't apply to a GitHub repository, for example).
    var provider: Provider = .vercel
    /// Newest fetched deployment/run for this project — fills the state badge and
    /// last-activity line for providers whose project API carries no latest-
    /// deployment info (GitHub repos).
    var latestRun: Deployment? = nil
    /// Account/team this row came from. Set only in the "All sources" view, where
    /// one list mixes scopes and two teams may share a project name.
    var scopeLabel: String? = nil
    /// Palette slot for `scopeLabel`'s marker dot, resolved by the store so a
    /// user override in Settings wins over the derived color.
    var scopeColorIndex: Int = 0
    /// The Vercel team / account that owns this project, shown as the title's
    /// `org/` prefix. Unlike `scopeLabel` this is set in every view, not just
    /// "All sources" — the owner is part of the project's name, not a marker.
    var ownerLabel: String? = nil
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            // Centered against the row's text, and carrying its own status dot —
            // the same cluster the deployments list uses. See `SourceIcon`.
            SourceIcon(state: displayState,
                       host: project.faviconHost,
                       directURL: project.iconURL)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    titleLine
                    if let scopeLabel {
                        ScopeDot(label: scopeLabel, color: ScopeColor.color(at: scopeColorIndex))
                    }
                }
                metaLine
                lastDeployLine
            }
            // See `DeploymentRow`: the text column, not a spacer, takes the
            // slack so hiding the action icons actually widens the content.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)

            // No state badge: the icon's status dot and its tooltip already say
            // what the row's state is, and the badge spent ~60pt repeating it.
            // The icons now sit in one centered row, as in `DeploymentRow`.
            actions
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .clipped()
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { self.hovering = hovering }
        }
    }

    // MARK: - Title (owner / project)

    /// "org/project", with the owner dimmed so the project name still reads as
    /// the row's subject. One `Text` rather than an `HStack`: concatenated runs
    /// truncate as a single string, so a long owner shortens the whole title
    /// instead of squeezing the project name out of the row.
    private var titleLine: some View {
        Group {
            if let owner = ProjectTitle.owner(scopeLabel: ownerLabel, project: project.name) {
                Text(owner + "/")
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                + Text(ProjectTitle.leaf(project.name))
                    .fontWeight(.semibold)
            } else {
                Text(ProjectTitle.leaf(project.name))
                    .fontWeight(.semibold)
            }
        }
        .font(.body)
        .lineLimit(1)
        // The owner prefix is the least important part of the title, so trim
        // there rather than at the project name's tail.
        .truncationMode(.head)
    }

    // MARK: - Metadata line (icon + value pairs)

    @ViewBuilder private var metaLine: some View {
        HStack(spacing: 12) {
            if let branch = project.productionBranch {
                MetaItem(symbol: "arrow.triangle.branch", text: branch)
            }
            if let fw = project.framework {
                MetaItem(symbol: "cube", text: fw)
            }
            if let stars = project.starCount, stars > 0 {
                MetaItem(symbol: "star", text: "\(stars)")
            }
            if let issues = project.openIssueCount, issues > 0 {
                MetaItem(symbol: "exclamationmark.circle", text: "\(issues)")
            }
            if project.isPrivate == true {
                MetaItem(symbol: "lock", text: String(localized: "private", comment: "Private repository chip"))
            }
            if project.cronCount > 0 {
                MetaItem(
                    symbol: "clock.arrow.circlepath",
                    text: String(localized: "\(project.cronCount) crons", comment: "Cron job count on a project; pluralized")
                )
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    // MARK: - State (project's own latest deployment, else the newest fetched run)

    private var displayState: DeploymentState {
        if project.latestStateRaw != nil { return project.latestState }
        return latestRun?.state ?? .unknown
    }

    /// Timestamp backing the last-activity line, matching `displayState`'s source.
    private var displayStateCreatedAt: Double? {
        if project.latestStateRaw != nil { return project.latestCreatedAt }
        return latestRun?.createdAt
    }

    // MARK: - Last-deploy line

    @ViewBuilder private var lastDeployLine: some View {
        if let text = lastDeployText {
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var lastDeployText: String? {
        let isCI = provider == .github
        switch displayState {
        case .building, .queued:
            return isCI
                ? String(localized: "running…", comment: "CI run in progress")
                : String(localized: "building…", comment: "Build in progress")
        case .ready, .error, .canceled, .unknown:
            guard let created = displayStateCreatedAt else {
                // No deployment/run info at all — fall back to the repo's last push.
                guard let pushed = project.pushedAt else { return nil }
                return String(localized: "pushed \(DeploymentTiming.relative(epochMs: pushed))",
                              comment: "Last push time when no CI runs are known")
            }
            let when = DeploymentTiming.relative(epochMs: created)
            switch displayState {
            case .ready:
                return isCI
                    ? String(localized: "✓ passed \(when)", comment: "Last successful CI run time")
                    : String(localized: "✓ deployed \(when)", comment: "Last successful deploy time")
            case .error: return String(localized: "⚠ failed \(when)", comment: "Last failed deploy time")
            default:     return when
            }
        }
    }

    // MARK: - Actions

    /// Direct links appear on hover; the overflow menu stays anchored so every
    /// row keeps a visible affordance and the cluster never collapses to
    /// nothing. See `DeploymentRow.actions` for the same reasoning.
    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            if hovering {
                linkActions
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }

            // Overflow menu holds provider-specific deep links.
            switch provider {
            case .vercel:      vercelOverflowMenu
            case .github:      githubOverflowMenu
            case .azureDevOps: EmptyView()
            }
        }
        .foregroundStyle(.secondary)
        .imageScale(.medium)
        // Reserve the hovered cluster's height up front. A bare `⋯` menu is
        // shorter than `IconActionButton`'s 30pt hit area, so without this the
        // arriving icons make this row taller — nudging `⋯` downward and
        // stretching the whole project row as you hover it.
        .frame(height: 30)
    }

    /// Production site and repository — the two direct links, shown on hover.
    @ViewBuilder private var linkActions: some View {
        if let prod = LinkBuilder.liveURL(host: project.productionURL) {
            IconActionButton(
                systemImage: "globe",
                url: prod,
                help: String(localized: "Open production site", comment: "Action tooltip")
            )
        }
        if let repo = LinkBuilder.githubRepo(org: project.repoOrg, repo: project.repoName) {
            IconActionButton(
                systemImage: "apple.terminal",
                url: repo,
                help: String(localized: "Open repository", comment: "Action tooltip")
            )
        }
    }

    @ViewBuilder private var githubOverflowMenu: some View {
        overflowMenu {
            if let pulls = LinkBuilder.githubPulls(org: project.repoOrg, repo: project.repoName) {
                Link(destination: pulls) {
                    Label("Pull requests", systemImage: "arrow.triangle.merge")
                }
            }
            if let issues = LinkBuilder.githubIssues(org: project.repoOrg, repo: project.repoName) {
                Link(destination: issues) {
                    Label("Issues", systemImage: "exclamationmark.circle")
                }
            }
            if let settings = LinkBuilder.githubRepoSettings(org: project.repoOrg, repo: project.repoName) {
                Link(destination: settings) {
                    Label("Repository settings", systemImage: "gearshape")
                }
            }
        }
    }

    @ViewBuilder private var vercelOverflowMenu: some View {
        overflowMenu {
            if let env = LinkBuilder.projectEnv(scope: scopeName, project: project.name) {
                Link(destination: env) {
                    Label("Environment variables", systemImage: "key.fill")
                }
            }
            if project.hasAnalytics,
               let analytics = LinkBuilder.projectAnalytics(scope: scopeName, project: project.name) {
                Link(destination: analytics) {
                    Label("Analytics", systemImage: "chart.bar.xaxis")
                }
            }
            if let settings = LinkBuilder.projectSettings(scope: scopeName, project: project.name) {
                Link(destination: settings) {
                    Label("Project settings", systemImage: "gearshape")
                }
            }
            if let dash = LinkBuilder.projectDashboard(scope: scopeName, project: project.name) {
                Link(destination: dash) {
                    Label("Vercel dashboard", systemImage: "square.grid.2x2")
                }
            }
        }
    }

    /// Shared ⋯ menu chrome around provider-specific links.
    ///
    /// Sized to the same 30pt box `IconActionButton` uses. A bare borderless
    /// `Menu` is only ~15pt tall, so in the actions `HStack` it would re-center
    /// itself vertically the moment the taller hover icons appeared beside it —
    /// the "⋯ drops down, then the icons slide out" sequence. Matching heights
    /// means nothing has to move.
    private func overflowMenu(@ViewBuilder _ content: () -> some View) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        // Without this the menu draws its disclosure chevron beside the glyph,
        // which makes the control ~14pt wider than the icons it sits next to
        // and reads as a dropdown rather than one more action button.
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 18, height: 18)
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .tooltip(String(localized: "More actions", comment: "Overflow menu tooltip"))
        .pointingHandCursor()
    }
}

/// A small SF Symbol paired with a value, used on the project metadata line.
private struct MetaItem: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(text)
        }
    }
}

/// Splits a project title into its owner prefix and the project's own name.
///
/// The two providers disagree on what `Project.name` holds: `GitHubClient` sets
/// it to the repo's full name (`owner/repo`), while Vercel sets a bare project
/// name and puts the owner in the scope. These rules produce one `owner/project`
/// title from either shape without ever doubling the owner up.
enum ProjectTitle {
    /// The owner to show before the project name, or nil when there is none to
    /// show (no scope, or a name that already carries its own owner).
    static func owner(scopeLabel: String?, project: String) -> String? {
        // A name like "octocat/hello" is already qualified — its own prefix wins,
        // otherwise a GitHub repo would render as "GitHub CLI/octocat/hello".
        if let embedded = embeddedOwner(project) { return embedded }
        guard let trimmed = scopeLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The project's own name, with any embedded owner stripped.
    static func leaf(_ project: String) -> String {
        guard let slash = project.firstIndex(of: "/") else { return project }
        return String(project[project.index(after: slash)...])
    }

    /// The owner baked into a `owner/repo` style name, if there is one.
    private static func embeddedOwner(_ project: String) -> String? {
        guard let slash = project.firstIndex(of: "/") else { return nil }
        let owner = String(project[..<slash])
        return owner.isEmpty ? nil : owner
    }
}
