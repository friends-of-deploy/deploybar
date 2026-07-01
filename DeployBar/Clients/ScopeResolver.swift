import Foundation

enum ScopeResolver {
    /// Resolves a human-readable scope name. For a team, fetches its slug;
    /// falls back to the teamId, or "personal" when there's no team.
    static func scopeName(credentials: VercelCredentials,
                          fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) async -> String {
        guard let teamId = credentials.teamId else { return "personal" }
        var req = URLRequest(url: URL(string: "https://api.vercel.com/v2/teams/\(teamId)")!)
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await fetch(req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let slug = obj["slug"] as? String, !slug.isEmpty {
                return slug
            }
        } catch { /* fall through to fallback */ }
        return teamId
    }
}
