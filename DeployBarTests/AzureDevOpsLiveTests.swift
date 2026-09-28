import XCTest
@testable import DeployBar

/// Talks to a real Azure DevOps organization. Skipped unless both variables
/// are set; xcodebuild forwards them with a `TEST_RUNNER_` prefix:
///
///     TEST_RUNNER_DEPLOYBAR_ADO_PAT=… TEST_RUNNER_DEPLOYBAR_ADO_ORG=… \
///     xcodebuild test … -only-testing:DeployBarTests/AzureDevOpsLiveTests
///
/// Read-only. Never commit a token.
@MainActor
final class AzureDevOpsLiveTests: XCTestCase {

    private func environment() throws -> (pat: String, org: String) {
        let env = ProcessInfo.processInfo.environment
        let pat = try XCTUnwrap(env["DEPLOYBAR_ADO_PAT"].flatMap { $0.isEmpty ? nil : $0 },
                                "set TEST_RUNNER_DEPLOYBAR_ADO_PAT")
        let org = try XCTUnwrap(env["DEPLOYBAR_ADO_ORG"].flatMap { $0.isEmpty ? nil : $0 },
                                "set TEST_RUNNER_DEPLOYBAR_ADO_ORG")
        return (pat, org)
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DEPLOYBAR_ADO_PAT"] != nil && env["DEPLOYBAR_ADO_ORG"] != nil,
                          "live Azure DevOps credentials not provided")
    }

    func test_realOrganizationEndToEnd() async throws {
        let (pat, org) = try environment()
        let account = Account(id: UUID(), provider: .azureDevOps, label: "live",
                              source: .keychain(account: "live"), organization: org)
        let integration = AzureDevOpsIntegration()

        let identity = try await integration.identity(for: account, using: .plain(pat))
        XCTAssertFalse(identity.username.isEmpty)

        let client = try XCTUnwrap(integration.client(for: Scope(account: account, teamId: org, teamName: org),
                                                      using: .plain(pat)) as? AzureDevOpsClient)
        let projects = try await client.projects()
        XCTAssertFalse(projects.isEmpty, "the organization has repositories")
        XCTAssertTrue(projects.allSatisfy { $0.name.contains("/") && $0.repoURL != nil })

        let runs = try await client.deployments(limit: 30)
        XCTAssertFalse(runs.isEmpty, "the organization has pipeline runs")
        XCTAssertTrue(runs.allSatisfy { AzureDevOpsClient.buildRef($0) != nil && $0.webURL != nil })
        XCTAssertTrue(runs.contains { $0.state != .unknown }, "at least some runs map to a known state")

        let reread = try await client.refreshed(Array(runs.prefix(3)))
        XCTAssertEqual(Set(reread.map(\.uid)), Set(runs.prefix(3).map(\.uid)))

        if let failed = runs.first(where: { $0.state == .error }) {
            let report = try await client.failureReport(for: failed)
            XCTAssertTrue(report.hasPrefix("Azure DevOps run failed"))
            XCTAssertTrue(report.contains("Failed task:") || report.contains("(no failed tasks reported)"))
        }
    }
}
