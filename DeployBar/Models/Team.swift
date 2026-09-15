import Foundation

/// `Codable` (not just `Decodable`) so the team list can be cached to disk:
/// it names every scope in the "All" view, and re-fetching it on each launch
/// would leave rows labelled with a raw `team_…` id until the network answers.
struct Team: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let slug: String?
    let name: String?
}

struct TeamsResponse: Decodable {
    let teams: [Team]
}
