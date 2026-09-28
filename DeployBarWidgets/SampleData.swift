import Foundation

extension WidgetSnapshot {
    /// Gallery placeholder and preview data — invented, like the demo fixtures.
    static func sample(now: Date = .now) -> WidgetSnapshot {
        func dep(_ id: String, _ state: String, _ minutesAgo: Double, _ message: String,
                 branch: String = "main", target: String = "production") -> WidgetDeployment {
            let created = now.addingTimeInterval(-minutesAgo * 60)
            return WidgetDeployment(id: id, stateRaw: state, target: target, branch: branch,
                                    shortSha: String(id.prefix(7)), message: message, author: "mira",
                                    createdAt: created, buildingAt: created.addingTimeInterval(5),
                                    readyAt: nil, url: URL(string: "https://example.com/\(id)"))
        }
        return WidgetSnapshot(generatedAt: now, projects: [
            WidgetProject(key: "sample|storefront", name: "storefront", provider: .vercel,
                          dashboardURL: URL(string: "https://example.com/storefront"), deployments: [
                dep("a1b2c3d4", "BUILDING", 2, "feat: add gift cards to checkout"),
                dep("b2c3d4e5", "READY", 45, "fix: currency rounding on cart totals"),
                dep("c3d4e5f6", "READY", 180, "chore: bump dependencies", branch: "deps", target: "preview"),
                dep("d4e5f6a7", "ERROR", 300, "feat: try edge caching", branch: "exp/edge", target: "preview"),
                dep("e5f6a7b8", "READY", 1500, "docs: update README"),
            ]),
            WidgetProject(key: "sample|api", name: "api", provider: .github,
                          dashboardURL: URL(string: "https://example.com/api"), deployments: [
                dep("f6a7b8c9", "READY", 70, "fix: paginate order export")]),
            WidgetProject(key: "sample|docs", name: "docs", provider: .vercel,
                          dashboardURL: nil, deployments: [
                dep("a7b8c9d0", "ERROR", 200, "chore: migrate search index")]),
            WidgetProject(key: "sample|marketing", name: "marketing", provider: .vercel,
                          dashboardURL: nil, deployments: [
                dep("b8c9d0e1", "READY", 2900, "feat: autumn campaign")]),
        ])
    }
}
