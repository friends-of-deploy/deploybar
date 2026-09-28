import Foundation

/// What the app hands the widget extension: followed projects and their latest
/// deployments, flattened so the extension needs none of the provider models.
///
/// The extension is sandboxed and has no network or credentials, so this file
/// is its only source of truth. `generatedAt` is when the data was fetched —
/// not when the file was written — so the widget can tell stale data apart.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Bumped on any incompatible change. A reader that meets a version it
    /// doesn't know treats the snapshot as absent rather than guessing.
    static let currentVersion = 1

    var version: Int
    var generatedAt: Date
    var projects: [WidgetProject]

    init(generatedAt: Date, projects: [WidgetProject]) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.projects = projects
    }

    /// Equal apart from `generatedAt` and each project's `updatedAt`: the
    /// publisher's "did anything change" test. A project's `updatedAt` moves on
    /// every successful poll of its scope even when nothing else about it
    /// changed, so counting it as content would trigger a reload every tick.
    func hasSameContent(as other: WidgetSnapshot) -> Bool {
        version == other.version
            && projects.map(\.withoutUpdatedAt) == other.projects.map(\.withoutUpdatedAt)
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

struct WidgetProject: Codable, Equatable, Sendable, Identifiable {
    /// `ProjectKey.storageString` — also the widget configuration's entity id.
    var key: String
    var name: String
    var provider: Provider
    var dashboardURL: URL?
    /// Newest first.
    var deployments: [WidgetDeployment]
    /// When this project's scope was last fetched successfully — the widgets'
    /// per-project staleness clock, distinct from the snapshot-wide
    /// `generatedAt` (which one scope's success can bump for every project,
    /// including a different scope's replayed rows).
    var updatedAt: Date

    var id: String { key }

    fileprivate var withoutUpdatedAt: WidgetProject {
        var copy = self
        copy.updatedAt = .distantPast
        return copy
    }
}

struct WidgetDeployment: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var stateRaw: String
    var target: String?
    var branch: String?
    var shortSha: String?
    var message: String?
    var author: String?
    var createdAt: Date
    var buildingAt: Date?
    var readyAt: Date?
    /// The deployment's page: inspector / Actions run, else the live URL.
    var url: URL?

    var state: DeploymentState { DeploymentState(apiValue: stateRaw) }
}
