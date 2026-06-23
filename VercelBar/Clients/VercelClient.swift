import Foundation

enum VercelClientError: Error, Equatable { case unauthorized, http(Int) }

struct VercelClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let decoder = JSONDecoder()

    let credentials: VercelCredentials
    let fetch: Fetch

    init(credentials: VercelCredentials,
         fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.credentials = credentials
        self.fetch = fetch
    }

    func deployments(limit: Int = 100) async throws -> [Deployment] {
        let data = try await get(path: "/v6/deployments", query: [URLQueryItem(name: "limit", value: String(limit))])
        return try Self.decoder.decode(DeploymentsResponse.self, from: data).deployments
    }

    // Fetch up to 100 projects; the menubar lists them all.
    func projects() async throws -> [Project] {
        let data = try await get(path: "/v9/projects", query: [URLQueryItem(name: "limit", value: "100")])
        return try Self.decoder.decode(ProjectsResponse.self, from: data).projects
    }

    /// The build log lines for a deployment, oldest first. Used to extract the
    /// failure output of an errored deployment for copying to the clipboard.
    func buildEvents(deploymentId: String) async throws -> [BuildEvent] {
        // `builds=1` includes build-step output; the response is a JSON array of events.
        let data = try await get(path: "/v3/deployments/\(deploymentId)/events",
                                 query: [URLQueryItem(name: "builds", value: "1")])
        return try Self.decoder.decode([BuildEvent].self, from: data)
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        var comps = URLComponents(string: "https://api.vercel.com\(path)")!
        var items = query
        if let team = credentials.teamId { items.append(URLQueryItem(name: "teamId", value: team)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await fetch(req)
        guard let http = response as? HTTPURLResponse else { throw VercelClientError.http(-1) }
        if http.statusCode == 401 || http.statusCode == 403 { throw VercelClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw VercelClientError.http(http.statusCode) }
        return data
    }
}
