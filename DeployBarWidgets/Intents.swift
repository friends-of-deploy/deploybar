import AppIntents
import WidgetKit

struct SelectProjectIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Project"
    static var description = IntentDescription("The status and latest deploys of one project.")

    @Parameter(title: "Project")
    var project: ProjectEntity?
}
