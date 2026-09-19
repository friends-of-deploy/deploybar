import Foundation

/// Lists the organizations the authenticated user belongs to.
///
/// Mirrors `TeamsClient`: a GitHub organization and a Vercel team are the same
/// thing to every consumer downstream, so both map onto `Team`. The org login
/// serves as the id because it is what `/orgs/{org}/repos` takes.
struct GitHubOrgsClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let decoder = JSONDecoder()

    let token: String
    let fetch: Fetch

    init(token: String,
         fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.token = token
        self.fetch = fetch
    }

    func organizations() async throws -> [Team] {
        var req = URLRequest(url: URL(string: "https://api.github.com/user/orgs?per_page=100")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await fetch(req)
        guard let http = response as? HTTPURLResponse else { throw ProviderClientError.http(-1) }
        // GitHub reports an exhausted quota as 403, so this must be checked
        // before the generic unauthorized mapping below.
        if http.isRateLimited { throw ProviderClientError.rateLimited(retryAfter: http.retryAfterSeconds) }
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ProviderClientError.http(http.statusCode) }

        return try Self.decoder.decode([GHOrg].self, from: data)
            .map { Team(id: $0.login, slug: $0.login, name: $0.login) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }
}
