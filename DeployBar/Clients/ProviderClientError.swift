import Foundation

/// Error surface shared by every provider client (Vercel, GitHub, …). The
/// aggregator branches on `.unauthorized` for token-refresh / logout handling
/// regardless of which provider raised it.
enum ProviderClientError: Error, Equatable {
    case unauthorized
    case http(Int)
}
