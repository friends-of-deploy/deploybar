import AppIntents
import WidgetKit

struct SelectProjectIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Project"
    static var description = IntentDescription("The status and latest deploys of one project.")

    @Parameter(title: "Project")
    var project: ProjectEntity?
}

struct SelectProjectsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Projects"
    static var description = IntentDescription("Several projects side by side.")

    /// Empty means "the most recently active followed projects".
    @Parameter(title: "Projects", size: [.systemSmall: 3, .systemMedium: 4, .systemLarge: 8])
    var projects: [ProjectEntity]?
}
