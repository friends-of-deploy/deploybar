import Foundation

/// The per-scope data surface every provider must offer. Teams/user are account-level
/// and handled separately by the aggregator.
protocol DeploymentProviderClient: Sendable {
    func deployments(limit: Int) async throws -> [Deployment]
    func projects() async throws -> [Project]
}

extension VercelClient: DeploymentProviderClient {}
