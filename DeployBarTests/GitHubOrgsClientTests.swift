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
        [{"owner":{"login":"Vorciu","type":"Organization"}},{"owner":{"login":"8lines","type":"Organization"}}]
        """.data(using: .utf8)!
        let client = GitHubOrgsClient(token: "t") { _ in (json, self.response(200)) }

        let orgs = try await client.organizations()

        XCTAssertEqual(orgs.map(\.id), ["8lines", "Vorciu"])
        XCTAssertEqual(orgs.first?.name, "8lines")
        XCTAssertEqual(orgs.first?.slug, "8lines")
    }

    func test_requestsAccessibleReposWithBearerToken() async throws {
        let json = "[]".data(using: .utf8)!
        var seen: URLRequest?
        let client = GitHubOrgsClient(token: "secret") { req in
            seen = req
            return (json, self.response(200))
        }

        _ = try await client.organizations()

        XCTAssertEqual(seen?.url?.path, "/user/repos")
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
    func test_fineGrainedTokenDiscoversUniqueOrganizationOwnersAcrossPages() async throws {
        var pages: [String] = []
        let client = GitHubOrgsClient(token: "fine-grained") { req in
            if req.url!.path == "/user/orgs" { return (Data("[]".utf8), self.response(200)) }
            let page = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
            pages.append(page)
            let entries = page == "1"
                ? Array(repeating: #"{"owner":{"login":"Acme","type":"Organization"}}"#, count: 100)
                : [#"{"owner":{"login":"other","type":"Organization"}}"#, #"{"owner":{"login":"person","type":"User"}}"#]
            return (Data(("[" + entries.joined(separator: ",") + "]").utf8), self.response(200))
        }
        let orgs = try await client.organizations()
        XCTAssertEqual(orgs.map(\.id), ["Acme", "other"])
        XCTAssertEqual(pages, ["1", "2"])
    }

}
