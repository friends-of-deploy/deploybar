import SwiftUI

private struct ProviderRegistryKey: EnvironmentKey {
    static let defaultValue = ProviderRegistry.live()
}

extension EnvironmentValues {
    /// The store's registry, for views that show provider-specific wording and links.
    var providerRegistry: ProviderRegistry {
        get { self[ProviderRegistryKey.self] }
        set { self[ProviderRegistryKey.self] = newValue }
    }
}
