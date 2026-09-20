import Foundation

/// Discovers organization owners among repositories accessible to the token.
/// `/user/orgs` returns an empty list for fine-grained PATs. Repository owners
/// work for those tokens too, without widening access to every public org repo.
/// Discovery stops after 10 pages of 100 repositories, sorted by recent push.
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
        struct Repository: Decodable {
            struct Owner: Decodable { let login: String; let type: String? }
            let owner: Owner
        }
        var names: [String: String] = [:]
        for page in 1...10 {
            let url = URL(string: "https://api.github.com/user/repos?sort=pushed&per_page=100&page=\(page)")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await fetch(req)
            guard let http = response as? HTTPURLResponse else { throw ProviderClientError.http(-1) }
            // GitHub reports an exhausted quota as 403, so this must be checked
            // before the generic unauthorized mapping below.
            if http.isRateLimited { throw ProviderClientError.rateLimited(retryAfter: http.retryAfterSeconds) }
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderClientError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw ProviderClientError.http(http.statusCode) }

            let repositories = try Self.decoder.decode([Repository].self, from: data)
            for repo in repositories where repo.owner.type == "Organization" {
                names[repo.owner.login.lowercased()] = repo.owner.login
            }
            if repositories.count < 100 { break }
        }
        return names.values.map { Team(id: $0, slug: $0, name: $0) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }
}
