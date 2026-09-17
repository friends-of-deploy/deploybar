import XCTest
@testable import DeployBar

/// Throttling used to be indistinguishable from a revoked token.
///
/// GitHub reports an exhausted rate limit as **403** (not 429), and both
/// clients mapped every 403 to `.unauthorized`. Three throttled polls then
/// crossed `authFailureThreshold` and told the user to reconnect a token that
/// was never invalid. Rate limiting is now its own case, is excluded from the
/// auth counter, and says so in the health list.
@MainActor
final class RateLimitTests: XCTestCase {

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.github.com/x")!,
                        statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - Classification

    func test_429IsRateLimited() {
        XCTAssertTrue(response(429).isRateLimited)
    }

    /// GitHub's primary limit: 403 with the quota header at zero.
    func test_403WithExhaustedQuotaIsRateLimited() {
        XCTAssertTrue(response(403, headers: ["x-ratelimit-remaining": "0"]).isRateLimited)
    }

    /// GitHub's secondary limit: 403 carrying `retry-after`.
    func test_403WithRetryAfterIsRateLimited() {
        XCTAssertTrue(response(403, headers: ["retry-after": "60"]).isRateLimited)
    }

    /// A genuine auth failure must stay an auth failure.
    func test_plain403IsNotRateLimited() {
        XCTAssertFalse(response(403).isRateLimited)
        XCTAssertFalse(response(403, headers: ["x-ratelimit-remaining": "4999"]).isRateLimited)
        XCTAssertFalse(response(401).isRateLimited)
    }

    func test_retryAfterParsedFromDelta() {
        XCTAssertEqual(response(429, headers: ["retry-after": "90"]).retryAfterSeconds, 90)
    }

    func test_retryAfterDerivedFromResetTimestamp() {
        let reset = Date().timeIntervalSince1970 + 120
        let secs = response(403, headers: ["x-ratelimit-remaining": "0",
                                           "x-ratelimit-reset": String(reset)]).retryAfterSeconds
        XCTAssertNotNil(secs)
        XCTAssertEqual(try XCTUnwrap(secs), 120, accuracy: 5)
    }

    // MARK: - Client mapping

    func test_githubClientThrowsRateLimitedNotUnauthorized() async {
        let client = GitHubClient(token: "t") { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil,
                                              headerFields: ["x-ratelimit-remaining": "0"])!)
        }
        do {
            _ = try await client.deployments(limit: 10)
            XCTFail("expected a throw")
        } catch ProviderClientError.rateLimited {
            // correct
        } catch ProviderClientError.unauthorized {
            XCTFail("a throttled 403 must not read as a revoked token")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_vercelClientThrowsRateLimitedOn429() async {
        let client = VercelClient(credentials: VercelCredentials(token: "t", teamId: nil)) { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil,
                                              headerFields: ["retry-after": "30"])!)
        }
        do {
            _ = try await client.deployments(limit: 10)
            XCTFail("expected a throw")
        } catch ProviderClientError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Store behaviour

    private struct ThrottledClient: DeploymentProviderClient {
        func deployments(limit: Int) async throws -> [Deployment] {
            throw ProviderClientError.rateLimited(retryAfter: 600)
        }
        func projects() async throws -> [Project] {
            throw ProviderClientError.rateLimited(retryAfter: 600)
        }
    }

    /// The core regression: sustained throttling must never be reported as a
    /// logout, however many polls it spans.
    func test_sustainedRateLimitingIsNotReportedAsLogout() async {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false },
                                        reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        _ = accountStore.addKeychainAccount(provider: .github, label: "GH", token: "tok")
        let store = DeploymentStore(
            accountStore: accountStore,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            makeClient: { _, _ in ThrottledClient() },
            reloadToken: { nil },
            authRetryBackoff: .zero
        )

        // Well past the 3-poll auth-failure threshold.
        for _ in 0..<6 { await store.poll() }

        let issues = store.healthIssues.joined(separator: "\n").lowercased()
        XCTAssertFalse(issues.isEmpty, "throttling should still be reported")
        XCTAssertTrue(issues.contains("rate limited"), "got: \(issues)")
        XCTAssertFalse(issues.contains("logged in"),
                       "a valid token must not be reported as logged out: \(issues)")
    }
}
