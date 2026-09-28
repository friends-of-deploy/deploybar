import Foundation

/// The providers this build can talk to. A provider absent here shows as
/// "coming soon" and cannot be added.
struct ProviderRegistry: Sendable {
    private let byProvider: [Provider: any ProviderIntegration]

    init(_ integrations: [any ProviderIntegration]) {
        byProvider = Dictionary(integrations.map { ($0.provider, $0) }, uniquingKeysWith: { _, last in last })
    }

    func integration(for provider: Provider) -> (any ProviderIntegration)? { byProvider[provider] }

    func isAvailable(_ provider: Provider) -> Bool { byProvider[provider] != nil }

    /// Registered integrations in `Provider.allCases` order.
    var all: [any ProviderIntegration] { Provider.allCases.compactMap { byProvider[$0] } }

    /// Fresh instances each call: an integration may hold per-store state
    /// (GitHub's per-tick repository listing).
    static func live() -> ProviderRegistry {
        ProviderRegistry([VercelIntegration(), GitHubIntegration(), AzureDevOpsIntegration()])
    }
}
