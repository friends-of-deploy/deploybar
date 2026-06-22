import Foundation

enum TokenError: Error, Equatable { case notLoggedIn }

struct VercelCredentials: Equatable, Sendable {
    let token: String
    let teamId: String?
}

struct TokenProvider {
    let configDirectory: URL

    init(configDirectory: URL? = nil) {
        if let configDirectory {
            self.configDirectory = configDirectory
        } else {
            // Vercel CLI stores credentials here on macOS.
            self.configDirectory = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.vercel.cli")
        }
    }

    func credentials() throws -> VercelCredentials {
        let authURL = configDirectory.appendingPathComponent("auth.json")
        guard let authData = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let token = auth["token"] as? String, !token.isEmpty
        else { throw TokenError.notLoggedIn }

        let configURL = configDirectory.appendingPathComponent("config.json")
        var teamId: String? = nil
        if let cfgData = try? Data(contentsOf: configURL),
           let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
           let team = cfg["currentTeam"] as? String, !team.isEmpty {
            teamId = team
        }
        return VercelCredentials(token: token, teamId: teamId)
    }
}
