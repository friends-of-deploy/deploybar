import SwiftUI
import WidgetKit

struct ProjectEntry: TimelineEntry {
    enum Content {
        case noSnapshot, noProjects, missing
        case project(WidgetProject)
    }

    let date: Date
    let content: Content
    let generatedAt: Date?
    let isStale: Bool

    static func sample(now: Date = .now) -> ProjectEntry {
        let snapshot = WidgetSnapshot.sample(now: now)
        return ProjectEntry(date: now, content: .project(snapshot.projects[0]),
                            generatedAt: now, isStale: false)
    }
}

struct ProjectProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ProjectEntry { .sample() }

    func snapshot(for configuration: SelectProjectIntent, in context: Context) async -> ProjectEntry {
        if context.isPreview { return .sample() }
        return entries(for: configuration, now: .now).first ?? .sample()
    }

    func timeline(for configuration: SelectProjectIntent, in context: Context) async -> Timeline<ProjectEntry> {
        let entries = entries(for: configuration, now: .now)
        widgetTimelineLog.log("project timeline: \(entries.count) entries")
        return Timeline(entries: entries, policy: .never)
    }

    private func entries(for configuration: SelectProjectIntent, now: Date) -> [ProjectEntry] {
        guard let snapshot = WidgetSnapshotFile.read() else {
            return [ProjectEntry(date: now, content: .noSnapshot, generatedAt: nil, isStale: false)]
        }
        let key = configuration.project?.id
        let content: ProjectEntry.Content
        let project = WidgetSelection.project(forKey: key, in: snapshot)
        if let project {
            content = .project(project)
        } else {
            content = key == nil ? .noProjects : .missing
        }
        guard let asOf = project?.updatedAt else {
            return [ProjectEntry(date: now, content: content, generatedAt: nil, isStale: false)]
        }
        return WidgetSelection.timelineMarks(generatedAt: asOf, now: now).map {
            ProjectEntry(date: $0.date, content: content, generatedAt: asOf, isStale: $0.isStale)
        }
    }
}

struct ProjectWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ProjectEntry

    var body: some View {
        Group {
            switch entry.content {
            case .noSnapshot:
                WidgetMessage("Open DeployBar to see deploys", systemImage: "arrow.up.forward.app")
            case .noProjects:
                WidgetMessage("Follow projects in DeployBar", systemImage: "star")
            case .missing:
                WidgetMessage("Project unavailable — edit the widget", systemImage: "questionmark.folder")
            case .project(let project):
                switch family {
                case .systemMedium: ProjectMediumView(project: project, entry: entry)
                case .systemLarge:  ProjectLargeView(project: project, entry: entry)
                default:            ProjectSmallView(project: project, entry: entry)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct ProjectSmallView: View {
    let project: WidgetProject
    let entry: ProjectEntry

    var body: some View {
        let featured = WidgetSelection.featured(in: project)
        VStack(alignment: .leading, spacing: 6) {
            ProjectTitle(project: project)
            Spacer(minLength: 0)
            if let featured {
                HStack(spacing: 6) {
                    StatusGlyph(state: featured.state, size: 20, isStale: entry.isStale)
                    Text(stateText(featured.state, isStale: entry.isStale))
                        .font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                }
                HStack(spacing: 4) {
                    if let branch = featured.branch { Text(branch).lineLimit(1); Text(verbatim: "·") }
                    DeployTime(deployment: featured, isStale: entry.isStale)
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No deploys yet").font(.caption).foregroundStyle(.secondary)
            }
            if entry.isStale, let generatedAt = entry.generatedAt { StaleFooter(generatedAt: generatedAt) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetSelection.link(for: project))
    }
}

private struct ProjectHeader: View {
    let project: WidgetProject
    let isStale: Bool

    var body: some View {
        HStack {
            OptionalLink(url: project.dashboardURL) { ProjectTitle(project: project) }
            Spacer()
            if let featured = WidgetSelection.featured(in: project) {
                HStack(spacing: 4) {
                    StatusGlyph(state: featured.state, isStale: isStale)
                    Text(stateText(featured.state, isStale: isStale)).font(.subheadline)
                }
            }
        }
    }
}

/// One deploy on one line: glyph, message, branch, time.
struct DeploymentLine: View {
    let deployment: WidgetDeployment
    let isStale: Bool

    var body: some View {
        OptionalLink(url: deployment.url) {
            HStack(spacing: 6) {
                StatusGlyph(state: deployment.state, size: 10, isStale: isStale)
                Text(deployment.message ?? deployment.shortSha ?? "—").lineLimit(1)
                Spacer(minLength: 4)
                if let branch = deployment.branch {
                    Text(branch).lineLimit(1).foregroundStyle(.secondary).frame(maxWidth: 80, alignment: .trailing)
                }
                DeployTime(deployment: deployment, isStale: isStale)
                    .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
            .font(.caption)
        }
    }
}

private struct ProjectMediumView: View {
    let project: WidgetProject
    let entry: ProjectEntry

    var body: some View {
        let featured = WidgetSelection.featured(in: project)
        VStack(alignment: .leading, spacing: 6) {
            ProjectHeader(project: project, isStale: entry.isStale)
            Divider()
            if let featured {
                OptionalLink(url: featured.url) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(featured.message ?? featured.shortSha ?? "—")
                            .font(.subheadline).lineLimit(2)
                        Text([featured.branch, featured.shortSha, targetText(featured.target)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 4) {
                            if let author = featured.author { Text(author); Text(verbatim: "·") }
                            DeployTime(deployment: featured, isStale: entry.isStale)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if featured.state.isInProgress, let last = WidgetSelection.lastFinished(in: project) {
                    DeploymentLine(deployment: last, isStale: entry.isStale)
                }
            } else {
                Text("No deploys yet").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.isStale, let generatedAt = entry.generatedAt { StaleFooter(generatedAt: generatedAt) }
        }
    }
}

private struct ProjectLargeView: View {
    let project: WidgetProject
    let entry: ProjectEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProjectHeader(project: project, isStale: entry.isStale)
            Divider()
            if project.deployments.isEmpty {
                Text("No deploys yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(project.deployments) { deployment in
                DeploymentLine(deployment: deployment, isStale: entry.isStale)
            }
            Spacer(minLength: 0)
            if entry.isStale, let generatedAt = entry.generatedAt { StaleFooter(generatedAt: generatedAt) }
        }
    }
}

struct ProjectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "io.eightlines.deploybar.project",
                               intent: SelectProjectIntent.self,
                               provider: ProjectProvider()) { entry in
            ProjectWidgetView(entry: entry)
        }
        .configurationDisplayName("Project")
        .description("The status and latest deploys of one project.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private let previewNow = Date.now

#Preview("Building", as: .systemSmall) { ProjectWidget() } timeline: { ProjectEntry.sample(now: previewNow) }
#Preview("Medium", as: .systemMedium) { ProjectWidget() } timeline: { ProjectEntry.sample(now: previewNow) }
#Preview("Large", as: .systemLarge) { ProjectWidget() } timeline: { ProjectEntry.sample(now: previewNow) }
#Preview("Stale", as: .systemMedium) { ProjectWidget() } timeline: {
    ProjectEntry(date: previewNow, content: .project(WidgetSnapshot.sample(now: previewNow).projects[0]),
                 generatedAt: previewNow.addingTimeInterval(-7200), isStale: true)
}
#Preview("Error", as: .systemSmall) { ProjectWidget() } timeline: {
    ProjectEntry(date: previewNow, content: .project(WidgetSnapshot.sample(now: previewNow).projects[2]),
                 generatedAt: previewNow, isStale: false)
}
#Preview("No snapshot", as: .systemSmall) { ProjectWidget() } timeline: {
    ProjectEntry(date: previewNow, content: .noSnapshot, generatedAt: nil, isStale: false)
}
#Preview("Missing", as: .systemSmall) { ProjectWidget() } timeline: {
    ProjectEntry(date: previewNow, content: .missing, generatedAt: nil, isStale: false)
}
