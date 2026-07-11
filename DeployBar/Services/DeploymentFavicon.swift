import Foundation

/// Picks the favicon host for a deployment.
///
/// A deployment's own `url` is the per-deployment generated host
/// (`myapp-a1b2c3d4-acme.vercel.app`) — it has no brand favicon of its own and
/// Google's favicon service can't resolve it either, so it never loads an icon.
/// Instead we resolve the favicon from the deployment's *project* (matched by
/// name), reusing the same "brandable host" rule the project list uses. We fall
/// back to the deployment's own URL only when there is no matching project.
enum DeploymentFavicon {
    static func host(for deployment: Deployment, in projects: [Project]) -> String? {
        if let project = projects.first(where: { $0.name == deployment.name }),
           let host = project.faviconHost {
            return host
        }
        return deployment.url.isEmpty ? nil : deployment.url
    }

    /// Direct icon URL fallback (e.g. a GitHub owner avatar) from the matching
    /// project, for deployments whose project has no production domain at all.
    static func directURL(for deployment: Deployment, in projects: [Project]) -> String? {
        projects.first { $0.name == deployment.name }?.iconURL
    }
}
