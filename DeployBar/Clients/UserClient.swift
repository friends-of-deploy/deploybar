import Foundation

struct UserClient {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    private static let decoder = JSONDecoder()

    let token: String
    let fetch: Fetch

    init(token: String,
         fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.token = token
        self.fetch = fetch
    }

    func user() async throws -> VercelUser {
        let url = URL(string: "https://api.vercel.com/v2/user")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await fetch(req)
        guard let http = response as? HTTPURLResponse else { throw VercelClientError.http(-1) }
        if http.statusCode == 401 || http.statusCode == 403 { throw VercelClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw VercelClientError.http(http.statusCode) }
        return try Self.decoder.decode(UserResponse.self, from: data).user
    }
}
