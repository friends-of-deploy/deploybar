import AppIntents

/// A followed project, as offered in the widget's edit sheet. Built from the
/// snapshot, so the list is exactly what DeployBar publishes.
struct ProjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static var defaultQuery = ProjectEntityQuery()

    let id: String
    let name: String
    /// Nil for a configured project that's no longer in the snapshot.
    let provider: Provider?

    var displayRepresentation: DisplayRepresentation {
        if let provider {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(provider.displayName)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    init(_ project: WidgetProject) {
        id = project.key
        name = project.name
        provider = project.provider
    }

    init(unavailable id: String) {
        self.id = id
        name = String(localized: "Unavailable project")
        provider = nil
    }
}

struct ProjectEntityQuery: EntityQuery {
    private func all() -> [ProjectEntity] {
        guard let snapshot = WidgetSnapshotFile.read() else { return [] }
        return WidgetSelection.recentlyActive(snapshot.projects).map(ProjectEntity.init)
    }

    /// Unknown ids come back as "unavailable" entities rather than being
    /// dropped: dropping them would reset the widget's choice to nil, and it
    /// would quietly fall back to a different project.
    func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
        let known = Dictionary(all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return identifiers.map { known[$0] ?? ProjectEntity(unavailable: $0) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] { all() }

    func defaultResult() async -> ProjectEntity? { all().first }
}
