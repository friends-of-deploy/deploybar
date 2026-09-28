import SwiftUI
import WidgetKit

struct ProjectsEntry: TimelineEntry {
    enum Content {
        case noSnapshot, noProjects, missing
        case projects([WidgetProject])
    }

    let date: Date
    let content: Content
    let generatedAt: Date?
    let isStale: Bool

    static func sample(now: Date = .now) -> ProjectsEntry {
        ProjectsEntry(date: now, content: .projects(WidgetSnapshot.sample(now: now).projects),
                      generatedAt: now, isStale: false)
    }
}

extension WidgetFamily {
    /// How many projects fit: small 3, medium 4 (2×2), large 8.
    var projectsLimit: Int {
        switch self {
        case .systemMedium: return 4
        case .systemLarge:  return 8
        default:            return 3
        }
    }
}

struct ProjectsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ProjectsEntry { .sample() }

    func snapshot(for configuration: SelectProjectsIntent, in context: Context) async -> ProjectsEntry {
        if context.isPreview { return .sample() }
        return entries(for: configuration, family: context.family, now: .now).first ?? .sample()
    }

    func timeline(for configuration: SelectProjectsIntent, in context: Context) async -> Timeline<ProjectsEntry> {
        let entries = entries(for: configuration, family: context.family, now: .now)
        widgetTimelineLog.log("projects timeline: \(entries.count) entries")
        return Timeline(entries: entries, policy: .never)
    }

    private func entries(for configuration: SelectProjectsIntent, family: WidgetFamily,
                         now: Date) -> [ProjectsEntry] {
        guard let snapshot = WidgetSnapshotFile.read() else {
            return [ProjectsEntry(date: now, content: .noSnapshot, generatedAt: nil, isStale: false)]
        }
        let chosen = (configuration.projects ?? []).map(\.id)
        let projects = WidgetSelection.projects(chosenKeys: chosen, in: snapshot, limit: family.projectsLimit)
        let content: ProjectsEntry.Content
        if !projects.isEmpty {
            content = .projects(projects)
        } else {
            content = chosen.isEmpty ? .noProjects : .missing
        }
        return WidgetSelection.timelineMarks(generatedAt: snapshot.generatedAt, now: now).map {
            ProjectsEntry(date: $0.date, content: content, generatedAt: snapshot.generatedAt, isStale: $0.isStale)
        }
    }
}

struct ProjectsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ProjectsEntry

    var body: some View {
        Group {
            switch entry.content {
            case .noSnapshot:
                WidgetMessage("Open DeployBar to see deploys", systemImage: "arrow.up.forward.app")
            case .noProjects:
                WidgetMessage("Follow projects in DeployBar", systemImage: "star")
            case .missing:
                WidgetMessage("Projects unavailable — edit the widget", systemImage: "questionmark.folder")
            case .projects(let projects):
                VStack(alignment: .leading, spacing: 6) {
                    switch family {
                    case .systemMedium: ProjectsGrid(projects: projects, isStale: entry.isStale)
                    case .systemLarge:  ProjectsList(projects: projects, isStale: entry.isStale, showsMessage: true)
                    default:
                        ProjectsList(projects: projects, isStale: entry.isStale, showsMessage: false)
                            .widgetURL(projects.first.flatMap(WidgetSelection.link(for:)))
                    }
                    Spacer(minLength: 0)
                    if entry.isStale, let generatedAt = entry.generatedAt { StaleFooter(generatedAt: generatedAt) }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct ProjectsList: View {
    let projects: [WidgetProject]
    let isStale: Bool
    let showsMessage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showsMessage ? 9 : 7) {
            ForEach(projects) { project in
                let featured = WidgetSelection.featured(in: project)
                OptionalLink(url: WidgetSelection.link(for: project)) {
                    HStack(spacing: 6) {
                        StatusGlyph(state: featured?.state ?? .unknown, size: 11, isStale: isStale)
                        Text(project.name).fontWeight(.medium).lineLimit(1)
                        if showsMessage, let message = featured?.message {
                            Text(message).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let featured {
                            DeployTime(deployment: featured, isStale: isStale).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private struct ProjectsGrid: View {
    let projects: [WidgetProject]
    let isStale: Bool

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: projects.count, by: 2)), id: \.self) { index in
                GridRow {
                    ProjectTile(project: projects[index], isStale: isStale)
                    if index + 1 < projects.count {
                        ProjectTile(project: projects[index + 1], isStale: isStale)
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }
}

private struct ProjectTile: View {
    let project: WidgetProject
    let isStale: Bool

    var body: some View {
        let featured = WidgetSelection.featured(in: project)
        OptionalLink(url: WidgetSelection.link(for: project)) {
            VStack(alignment: .leading, spacing: 3) {
                ProjectTitle(project: project)
                HStack(spacing: 4) {
                    StatusGlyph(state: featured?.state ?? .unknown, size: 10, isStale: isStale)
                    if let featured {
                        Text(stateText(featured.state, isStale: isStale)).lineLimit(1)
                        Text(verbatim: "·")
                        DeployTime(deployment: featured, isStale: isStale)
                    } else {
                        Text("No deploys yet")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProjectsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "io.eightlines.deploybar.projects",
                               intent: SelectProjectsIntent.self,
                               provider: ProjectsProvider()) { entry in
            ProjectsWidgetView(entry: entry)
        }
        .configurationDisplayName("Projects")
        .description("Several projects side by side.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private let previewNow = Date.now

#Preview("Small", as: .systemSmall) { ProjectsWidget() } timeline: { ProjectsEntry.sample(now: previewNow) }
#Preview("Medium", as: .systemMedium) { ProjectsWidget() } timeline: { ProjectsEntry.sample(now: previewNow) }
#Preview("Large", as: .systemLarge) { ProjectsWidget() } timeline: { ProjectsEntry.sample(now: previewNow) }
#Preview("Stale", as: .systemLarge) { ProjectsWidget() } timeline: {
    ProjectsEntry(date: previewNow, content: .projects(WidgetSnapshot.sample(now: previewNow).projects),
                  generatedAt: previewNow.addingTimeInterval(-7200), isStale: true)
}
#Preview("Nothing followed", as: .systemSmall) { ProjectsWidget() } timeline: {
    ProjectsEntry(date: previewNow, content: .noProjects, generatedAt: previewNow, isStale: false)
}
