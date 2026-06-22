import SwiftUI

struct ProjectRow: View {
    let project: Project
    let scopeName: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Status dot + favicon cluster
            HStack(spacing: 6) {
                StatusDot(state: project.latestState)
                FaviconView(host: project.faviconHost)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.body)
                    .fontWeight(.semibold)

                chips
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
    }

    // MARK: - Stat chips

    @ViewBuilder private var chips: some View {
        HStack(spacing: 5) {
            if let fw = project.framework {
                StatChip(text: fw)
            }
            if let branch = project.productionBranch {
                StatChip(text: branch)
            }
            StatChip(text: "\(project.envCount) env")
            if let node = project.nodeVersion {
                StatChip(text: "node \(node)")
            }
            if project.cronCount > 0 {
                StatChip(text: "\(project.cronCount) cron\(project.cronCount == 1 ? "" : "s")")
            }
        }
        .lineLimit(1)
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            // Inline: production site, env vars, repository
            if let prod = LinkBuilder.liveURL(host: project.productionURL) {
                Link(destination: prod) {
                    Image(systemName: "globe")
                }
                .help("Open production site")
            }
            if let env = LinkBuilder.projectEnv(scope: scopeName, project: project.name) {
                Link(destination: env) {
                    Image(systemName: "key.fill")
                }
                .help("Edit environment variables")
            }
            if let repo = LinkBuilder.githubRepo(org: project.repoOrg, repo: project.repoName) {
                Link(destination: repo) {
                    Image(systemName: "arrow.triangle.branch")
                }
                .help("Open repository")
            }

            // Overflow menu: analytics (conditional), settings, dashboard
            overflowMenu
        }
        .foregroundStyle(.secondary)
        .imageScale(.medium)
    }

    @ViewBuilder private var overflowMenu: some View {
        Menu {
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
        .help("More actions")
    }
}
