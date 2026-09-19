import XCTest
@testable import DeployBar

/// The GitHub organization list: decoding, sorting, and error mapping.
@MainActor
final class GitHubOrgsClientTests: XCTestCase {

    private nonisolated func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.github.com/user/orgs")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func test_decodesOrganizationsAsTeams() async throws {
        let json = """
        [{"login":"Vorciu","description":"a"},{"login":"8lines","description":null}]
        """.data(using: .utf8)!
        let client = GitHubOrgsClient(token: "t") { _ in (json, self.response(200)) }

        let orgs = try await client.organizations()

        XCTAssertEqual(orgs.map(\.id), ["8lines", "Vorciu"])
        XCTAssertEqual(orgs.first?.name, "8lines")
        XCTAssertEqual(orgs.first?.slug, "8lines")
    }

    func test_requestsUserOrgsWithBearerToken() async throws {
        let json = "[]".data(using: .utf8)!
        var seen: URLRequest?
        let client = GitHubOrgsClient(token: "secret") { req in
            seen = req
            return (json, self.response(200))
        }

        _ = try await client.organizations()

        XCTAssertEqual(seen?.url?.path, "/user/orgs")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func test_rateLimitIsReportedAsRateLimited() async {
        let client = GitHubOrgsClient(token: "t") { _ in
            (Data("{}".utf8),
             HTTPURLResponse(url: URL(string: "https://api.github.com/user/orgs")!,
                             statusCode: 403, httpVersion: nil,
                             headerFields: ["x-ratelimit-remaining": "0"])!)
        }

        do {
            _ = try await client.organizations()
            XCTFail("expected a rate-limit error")
        } catch {
            guard case ProviderClientError.rateLimited = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
        }
    }
}
