import Foundation

/// The per-scope data surface every provider must offer. Teams/user are account-level
/// and handled separately by the aggregator.
protocol DeploymentProviderClient: Sendable {
    func deployments(limit: Int) async throws -> [Deployment]
    func projects() async throws -> [Project]

    /// Re-reads specific deployments by id — far cheaper than a full scope
    /// fetch. Used for in-progress rows of scopes the poll budget deferred, so
    /// a finished run doesn't show as building until its scope comes round.
    /// Returns the fresh copies it could read; missing ids keep their old row.
    func refreshed(_ deployments: [Deployment]) async throws -> [Deployment]
}

extension DeploymentProviderClient {
    /// Providers without a by-id lookup refresh only on their scope's turn.
    func refreshed(_ deployments: [Deployment]) async throws -> [Deployment] { [] }
}

extension VercelClient: DeploymentProviderClient {}
