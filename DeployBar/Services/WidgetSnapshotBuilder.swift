import Foundation

/// Flattens the store's rows into what the widget extension renders.
enum WidgetSnapshotBuilder {
    static let maxDeploymentsPerProject = 6

    /// - Parameter projects: already narrowed to followed projects of enabled
    ///   scopes — the builder publishes whatever it's given.
    /// - Parameter generatedAt: when the snapshot was built/published, not
    ///   when any particular project's scope was last fetched.
    /// - Parameter updatedAt: when a project's own scope was last fetched
    ///   successfully — each project's per-scope freshness clock.
    static func build(projects: [SourcedProject],
                      deployments: [SourcedDeployment],
                      dashboardURL: (SourcedProject) -> URL?,
                      generatedAt: Date,
                      updatedAt: (SourcedProject) -> Date) -> WidgetSnapshot {
        let items = projects.deduplicated(by: \.key).map { sp in
            // Same association as `DeploymentStore.latestDeployment(for:)`.
            let deps = deployments
                .filter { $0.account.id == sp.account.id && $0.deployment.name == sp.project.name }
                .map(\.deployment)
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(maxDeploymentsPerProject)
                .map(widgetDeployment)
            return WidgetProject(key: sp.key.storageString, name: sp.project.name,
                                 provider: sp.account.provider,
                                 dashboardURL: dashboardURL(sp), deployments: deps,
                                 updatedAt: updatedAt(sp))
        }
        return WidgetSnapshot(generatedAt: generatedAt, projects: items)
    }

    private static func widgetDeployment(_ d: Deployment) -> WidgetDeployment {
        WidgetDeployment(id: d.uid, stateRaw: d.stateRaw, target: publishedTarget(d.target),
                         branch: d.commitRef, shortSha: d.commitSha.map { String($0.prefix(7)) },
                         message: d.commitMessage, author: d.commitAuthorLogin ?? d.creatorUsername,
                         createdAt: date(ms: d.createdAt), buildingAt: d.buildingAt.map(date(ms:)),
                         readyAt: d.ready.map(date(ms:)), url: LinkBuilder.deploymentPage(for: d))
    }

    /// GitHub and Azure DevOps clients put the branch name into `Deployment.target`,
    /// which only means something for Vercel's "production"/"preview" values —
    /// anything else must publish as nil rather than be mislabeled downstream
    /// (`targetText` maps every non-"production" value to "Preview").
    private static func publishedTarget(_ target: String?) -> String? {
        target == "production" || target == "preview" ? target : nil
    }

    /// Provider timestamps are epoch milliseconds.
    private static func date(ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
