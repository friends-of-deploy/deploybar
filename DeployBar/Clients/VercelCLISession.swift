import Foundation
import Darwin

/// Shared authenticated transport for requests made with the CLI's saved login.
actor VercelCLISession {
    static let shared = VercelCLISession()
    private let provider: TokenProvider
    private let fetch: VercelClient.Fetch
    private let now: @Sendable () -> Date
    private var refreshTask: Task<String, Error>?

    private struct Auth: Decodable, Equatable {
        let token: String
        let refreshToken: String?
        let expiresAt: TimeInterval?
        let userId: String?
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval
        let token_type: String
    }

    init(provider: TokenProvider = TokenProvider(),
         now: @escaping @Sendable () -> Date = { Date() },
         fetch: @escaping VercelClient.Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.provider = provider
        self.now = now
        self.fetch = fetch
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        let token = try await validToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let result = try await fetch(request)
        // A 403 may mean missing team permissions. Only a 401 warrants renewal.
        guard (result.1 as? HTTPURLResponse)?.statusCode == 401 else { return result }
        let renewed = try await validToken(rejectedToken: token)
        guard renewed != token else { return result }
        request.setValue("Bearer \(renewed)", forHTTPHeaderField: "Authorization")
        return try await fetch(request) // At most one retry, even if the new token is rejected.
    }

    private var authURL: URL { provider.configDirectory.appendingPathComponent("auth.json") }

    private func readAuth() throws -> Auth {
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(Auth.self, from: data), !auth.token.isEmpty
        else { throw ProviderClientError.unauthorized }
        return auth
    }

    private func validToken(rejectedToken: String? = nil) async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let auth = try readAuth()
        // CLI expiry is seconds since the epoch. Renew slightly early to avoid
        // expiring between the deployments and projects requests.
        let expiresSoon = auth.expiresAt.map { $0 <= now().timeIntervalSince1970 + 60 } ?? false
        guard expiresSoon || auth.token == rejectedToken else { return auth.token }
        guard let refreshToken = auth.refreshToken, !refreshToken.isEmpty else {
            // Legacy CLI and personal tokens have no refresh token; let the API
            // decide whether they are still usable.
            return auth.token
        }
        let task = Task { try await self.renew(auth, refreshToken: refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func renew(_ auth: Auth, refreshToken: String) async throws -> String {
        // Same public OAuth client and endpoint used by Vercel CLI:
        // github.com/vercel/vercel/blob/main/packages/cli/src/util/oauth.ts
        var request = URLRequest(url: URL(string: "https://api.vercel.com/login/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            ("client_id", "cl_HYyOPBNtFMfHhaUn9L4QPfTZz6TP47bp"),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)

        let result: (Data, URLResponse)
        do { result = try await fetch(request) }
        catch {
            // The CLI may have renewed the session while our request was in flight.
            let current = try readAuth()
            if current != auth { return current.token }
            throw error
        }
        let current = try readAuth()
        guard current == auth else { return current.token }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw ProviderClientError.http(-1) }
        if http.isRateLimited { throw ProviderClientError.rateLimited(retryAfter: http.retryAfterSeconds) }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if code == "invalid_grant" || http.statusCode == 401 {
                throw ProviderClientError.unauthorized
            }
            throw ProviderClientError.http(http.statusCode)
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !tokens.access_token.isEmpty, tokens.token_type.lowercased() == "bearer",
              tokens.expires_in > 0, tokens.expires_in.isFinite,
              tokens.refresh_token == nil || tokens.refresh_token?.isEmpty == false
        else { throw ProviderClientError.http(-1) }

        // Re-read immediately before writing: preserve CLI metadata and do not
        // restore a session that was logged out or replaced during the request.
        let saved = try Data(contentsOf: authURL)
        let latest = try JSONDecoder().decode(Auth.self, from: saved)
        guard latest == auth else { return latest.token }
        var object = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        object["token"] = tokens.access_token
        object["refreshToken"] = tokens.refresh_token ?? auth.refreshToken
        object["expiresAt"] = floor(now().timeIntervalSince1970) + tokens.expires_in
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try persist(updated)
        return tokens.access_token
    }

    private func persist(_ data: Data) throws {
        // Create privately, then atomically replace: readers never see half JSON,
        // and even the temporary file is owner-only from the moment it exists.
        let temporary = authURL.deletingLastPathComponent().appendingPathComponent(".deploybar-auth-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, authURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
