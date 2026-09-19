import XCTest
@testable import DeployBar

final class VercelCLISessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func directory(_ auth: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try auth.write(to: directory.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func session(_ directory: URL, transport: Transport) -> VercelCLISession {
        VercelCLISession(provider: TokenProvider(configDirectory: directory), now: { self.now },
                         fetch: { try await transport.fetch($0) })
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://api.vercel.com/v2/user")!)
    }

    func test_expiredTokenIsRenewedAndRotatedCredentialsArePersisted() async throws {
        let dir = try directory(#"{"token":"old","refreshToken":"refresh +&=","expiresAt":9000,"userId":"user_test","custom":"keep"}"#)
        let transport = Transport()
        let response = try await session(dir, transport: transport).data(for: request())
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 200)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("auth.json"))) as! [String: Any]
        XCTAssertEqual(saved["token"] as? String, "new")
        XCTAssertEqual(saved["refreshToken"] as? String, "rotated")
        XCTAssertEqual(saved["expiresAt"] as? Double, 13_600)
        XCTAssertEqual(saved["userId"] as? String, "user_test")
        XCTAssertEqual(saved["custom"] as? String, "keep")
        let requests = await transport.requests
        let refresh = try XCTUnwrap(requests.first { $0.url?.path == "/login/oauth/token" })
        XCTAssertEqual(refresh.httpMethod, "POST")
        XCTAssertEqual(refresh.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(refresh.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("refresh_token=refresh%20%2B%26%3D"))
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("client_id=cl_HYyOPBNtFMfHhaUn9L4QPfTZz6TP47bp"))
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("auth.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_validAndLegacyTokensDoNotRefresh() async throws {
        for auth in [#"{"token":"new","expiresAt":20000,"refreshToken":"r"}"#, #"{"token":"new"}"#] {
            let dir = try directory(auth)
            let transport = Transport()
            let response = try await session(dir, transport: transport).data(for: request())
            XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 200)
            let count = await transport.refreshCount
            XCTAssertEqual(count, 0)
        }
    }

    func test_concurrentRequestsShareOneRefresh() async throws {
        let dir = try directory(#"{"token":"old","expiresAt":9000,"refreshToken":"r"}"#)
        let transport = Transport()
        let session = session(dir, transport: transport)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 {
                group.addTask { (try await session.data(for: self.request()).1 as! HTTPURLResponse).statusCode }
            }
            for try await status in group { XCTAssertEqual(status, 200) }
        }
        let count = await transport.refreshCount
        XCTAssertEqual(count, 1)
    }

    func test_unauthorizedTokenRefreshesEvenBeforeRecordedExpiry() async throws {
        let dir = try directory(#"{"token":"old","expiresAt":20000,"refreshToken":"r"}"#)
        let transport = Transport()
        let response = try await session(dir, transport: transport).data(for: request())
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 200)
        let count = await transport.refreshCount
        XCTAssertEqual(count, 1)
    }

    func test_networkFailurePreservesCredentialsAndNextAttemptRecovers() async throws {
        let auth = #"{"token":"old","expiresAt":9000,"refreshToken":"r"}"#
        let dir = try directory(auth)
        let transport = Transport(failRefreshOnce: true)
        let session = session(dir, transport: transport)
        do {
            _ = try await session.data(for: request())
            XCTFail("Expected a network error")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("auth.json")), auth)
        let response = try await session.data(for: request())
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 200)
    }

    func test_invalidGrantRequiresLoginWithoutDeletingCredentials() async throws {
        let auth = #"{"token":"old","expiresAt":9000,"refreshToken":"r"}"#
        let dir = try directory(auth)
        let transport = Transport(refreshStatus: 400, refreshBody: #"{"error":"invalid_grant"}"#)
        do {
            _ = try await session(dir, transport: transport).data(for: request())
            XCTFail("Expected unauthorized")
        } catch { XCTAssertEqual(error as? ProviderClientError, .unauthorized) }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("auth.json")), auth)
    }

    func test_externalRotationDuringRefreshIsNotOverwritten() async throws {
        let dir = try directory(#"{"token":"old","expiresAt":9000,"refreshToken":"r"}"#)
        let transport = Transport(beforeRefreshResponse: {
            try #"{"token":"external","expiresAt":30000,"refreshToken":"external-r"}"#
                .write(to: dir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        })
        _ = try await session(dir, transport: transport).data(for: request())
        XCTAssertEqual(try TokenProvider(configDirectory: dir).credentials().token, "external")
        let last = await transport.requests.last
        XCTAssertEqual(last?.value(forHTTPHeaderField: "Authorization"), "Bearer external")
    }

    func test_refreshWithoutReplacementRefreshTokenKeepsExistingOne() async throws {
        let dir = try directory(#"{"token":"old","expiresAt":9000,"refreshToken":"keep-r"}"#)
        let transport = Transport(refreshBody: #"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#)
        _ = try await session(dir, transport: transport).data(for: request())
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("auth.json"))) as! [String: Any]
        XCTAssertEqual(saved["refreshToken"] as? String, "keep-r")
    }

    func test_invalidRefreshResponsesNeverOverwriteSavedLogin() async throws {
        let auth = #"{"token":"old","expiresAt":9000,"refreshToken":"r"}"#
        for body in ["not json", #"{"access_token":"","expires_in":3600,"token_type":"Bearer"}"#,
                     #"{"access_token":"new","expires_in":0,"token_type":"Bearer"}"#,
                     #"{"access_token":"new","expires_in":3600,"refresh_token":"","token_type":"Bearer"}"#] {
            let dir = try directory(auth)
            do {
                _ = try await session(dir, transport: Transport(refreshBody: body)).data(for: request())
                XCTFail("Expected invalid token response to fail")
            } catch { XCTAssertNotEqual(error as? ProviderClientError, .unauthorized) }
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("auth.json")), auth)
        }
    }

    func test_rateLimitAndServerFailureAreNotReportedAsLogout() async throws {
        for status in [429, 500] {
            let dir = try directory(#"{"token":"old","expiresAt":9000,"refreshToken":"r"}"#)
            do {
                _ = try await session(dir, transport: Transport(refreshStatus: status)).data(for: request())
                XCTFail("Expected refresh failure")
            } catch {
                XCTAssertEqual(error as? ProviderClientError,
                               status == 429 ? .rateLimited(retryAfter: nil) : .http(500))
            }
        }
    }

    func test_forbiddenDoesNotRenewAndUnauthorizedRetriesOnlyOnce() async throws {
        for status in [403, 401] {
            let dir = try directory(#"{"token":"old","expiresAt":20000,"refreshToken":"r"}"#)
            let transport = Transport(apiStatus: status)
            let response = try await session(dir, transport: transport).data(for: request())
            XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, status)
            let count = await transport.refreshCount
            let requests = await transport.requests
            XCTAssertEqual(count, status == 401 ? 1 : 0)
            XCTAssertEqual(requests.filter { $0.url?.path == "/v2/user" }.count, status == 401 ? 2 : 1)
        }
    }

    func test_logoutDuringRefreshDoesNotRestoreSession() async throws {
        let dir = try directory(#"{"token":"old","expiresAt":9000,"refreshToken":"r"}"#)
        let transport = Transport(beforeRefreshResponse: {
            try FileManager.default.removeItem(at: dir.appendingPathComponent("auth.json"))
        })
        do {
            _ = try await session(dir, transport: transport).data(for: request())
            XCTFail("Expected logout to win")
        } catch { XCTAssertEqual(error as? ProviderClientError, .unauthorized) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("auth.json").path))
    }

    @MainActor
    func test_productionStoreRenewsForPollingTeamsAndUser() async throws {
        let dir = try directory(#"{"token":"old","expiresAt":9000,"refreshToken":"r"}"#)
        let transport = Transport()
        let provider = TokenProvider(configDirectory: dir)
        let accounts = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    credentials: InMemoryCredentialStore(), detectCLI: { true },
                                    reloadCLIToken: { try? provider.credentials().token },
                                    detectGitHubCLI: { false }, vercelCLISession: session(dir, transport: transport))
        let store = DeploymentStore(accountStore: accounts,
                                    settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                    reloadToken: { try? provider.credentials().token }, authRetryBackoff: .zero)
        async let poll: Void = store.poll()
        async let teams: Void = store.loadTeams()
        async let user: Void = store.loadUser()
        _ = await (poll, teams, user)
        XCTAssertEqual(store.deployments.map(\.uid), ["dpl_test"])
        XCTAssertEqual(store.projects.map(\.id), ["prj_test"])
        XCTAssertEqual(store.user?.username, "tester")
        XCTAssertTrue(store.healthIssues.isEmpty)
        let requests = await transport.requests
        XCTAssertTrue(requests.contains { $0.url?.path == "/v2/teams" })
        XCTAssertTrue(requests.filter { $0.url?.path != "/login/oauth/token" }.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer new"
        })
        let count = await transport.refreshCount
        XCTAssertEqual(count, 1)
    }

    private actor Transport {
        var requests: [URLRequest] = []
        var refreshCount = 0
        var failRefreshOnce: Bool
        let refreshStatus: Int
        let refreshBody: String
        let apiStatus: Int?
        let beforeRefreshResponse: () throws -> Void

        init(failRefreshOnce: Bool = false, refreshStatus: Int = 200,
             refreshBody: String = #"{"access_token":"new","refresh_token":"rotated","expires_in":3600,"token_type":"Bearer"}"#,
             apiStatus: Int? = nil, beforeRefreshResponse: @escaping () throws -> Void = {}) {
            self.failRefreshOnce = failRefreshOnce
            self.refreshStatus = refreshStatus
            self.refreshBody = refreshBody
            self.apiStatus = apiStatus
            self.beforeRefreshResponse = beforeRefreshResponse
        }

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let status: Int
            let body: String
            if request.url!.path == "/login/oauth/token" {
                refreshCount += 1
                await Task.yield()
                if failRefreshOnce {
                    failRefreshOnce = false
                    throw URLError(.notConnectedToInternet)
                }
                try beforeRefreshResponse()
                status = refreshStatus
                body = refreshBody
            } else {
                status = apiStatus ?? (request.value(forHTTPHeaderField: "Authorization") == "Bearer old" ? 401 : 200)
                switch request.url!.path {
                case "/v6/deployments":
                    body = #"{"deployments":[{"uid":"dpl_test","name":"test","state":"READY","url":"test.vercel.app","createdAt":1000}]}"#
                case "/v9/projects": body = #"{"projects":[{"id":"prj_test","name":"test"}]}"#
                case "/v2/teams": body = #"{"teams":[]}"#
                case "/v2/user": body = #"{"user":{"id":"user_test","username":"tester"}}"#
                default: body = "{}"
                }
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
