import Foundation

/// Vercel keeps its historical name; it's now an alias of the shared error type
/// so both `VercelClient` and `GitHubClient` throw one thing the aggregator handles.
typealias VercelClientError = ProviderClientError

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

    /// All projects in the scope. `/v9/projects` pages at 100; we follow the
    /// `pagination.next` cursor until it's nil so teams with >100 projects aren't
    /// silently truncated. Capped at 50 pages (5000 projects) as a runaway guard.
    func projects() async throws -> [Project] {
        var all: [Project] = []
        var until: Double?
        for _ in 0..<50 {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let until { query.append(URLQueryItem(name: "until", value: String(Int(until)))) }
            let data = try await get(path: "/v9/projects", query: query)
            let page = try Self.decoder.decode(ProjectsResponse.self, from: data)
            all.append(contentsOf: page.projects)
            guard let next = page.pagination?.next else { break }
            until = next
        }
        return all
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
        // Before the auth check: a throttled 403 is not a credential problem.
        if http.isRateLimited { throw VercelClientError.rateLimited(retryAfter: http.retryAfterSeconds) }
        if http.statusCode == 401 || http.statusCode == 403 { throw VercelClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw VercelClientError.http(http.statusCode) }
        return data
    }
}
