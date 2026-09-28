import Foundation

/// The organizations an Azure DevOps token can see, via the global profile
/// and accounts APIs. Those APIs refuse an org-scoped PAT with 401, which is
/// reported as `AccountValidationError.organizationRequired`; a rejected PAT
/// (203 sign-in page) stays `.unauthorized`.
struct AzureDevOpsOrgsClient: Sendable {
    private static let decoder = JSONDecoder()

    let token: String
    let fetch: HTTPFetch

    init(token: String, fetch: @escaping HTTPFetch = { try await URLSession.shared.data(for: $0) }) {
        self.token = token
        self.fetch = fetch
    }

    private struct Profile: Decodable { let id: String; let displayName: String? }
    private struct Membership: Decodable { let accountName: String }

    func displayName() async throws -> String {
        let profile = try await self.profile()
        return profile.displayName ?? profile.id
    }

    func organizations() async throws -> [Team] {
        let profile = try await self.profile()
        let data = try await get("/_apis/accounts", query: [URLQueryItem(name: "memberId", value: profile.id)])
        return try Self.decoder.decode(ADOList<Membership>.self, from: data).value
            .map { Team(id: $0.accountName, slug: $0.accountName, name: $0.accountName) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private func profile() async throws -> Profile {
        try Self.decoder.decode(Profile.self, from: try await get("/_apis/profile/profiles/me", query: []))
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "app.vssps.visualstudio.com"
        components.path = path
        components.queryItems = [URLQueryItem(name: "api-version", value: "7.1")] + query
        var request = URLRequest(url: components.url!)
        request.setValue(AzureDevOpsClient.basicAuthorization(token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw AccountValidationError.organizationRequired }
        try AzureDevOpsClient.check(response)
        return data
    }
}
