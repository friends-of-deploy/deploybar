import SwiftUI

struct ProjectRow: View {
    let project: Project
    let scopeName: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FaviconView(host: project.faviconHost)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.body)
                    .fontWeight(.semibold)
                metaLine
                lastDeployLine
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                StateBadge(state: project.latestState)
                actions
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering = $0 }
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
        switch project.latestState {
        case .building, .queued:
            return String(localized: "building…", comment: "Build in progress")
        case .ready, .error, .canceled, .unknown:
            guard let created = project.latestCreatedAt else { return nil }
            let when = DeploymentTiming.relative(epochMs: created)
            switch project.latestState {
            case .ready: return String(localized: "✓ deployed \(when)", comment: "Last successful deploy time")
            case .error: return String(localized: "⚠ failed \(when)", comment: "Last failed deploy time")
            default:     return when
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            // Inline: production site, repository
            if let prod = LinkBuilder.liveURL(host: project.productionURL) {
                IconActionButton(
                    systemImage: "globe",
                    url: prod,
                    help: String(localized: "Open production site", comment: "Action tooltip")
                )
            }
            if let repo = LinkBuilder.githubRepo(org: project.repoOrg, repo: project.repoName) {
                IconActionButton(
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    url: repo,
                    help: String(localized: "Open repository", comment: "Action tooltip")
                )
            }

            // Overflow menu: analytics (conditional), settings, dashboard
            overflowMenu
        }
        .foregroundStyle(.secondary)
        .imageScale(.medium)
    }

    @ViewBuilder private var overflowMenu: some View {
        Menu {
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
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
