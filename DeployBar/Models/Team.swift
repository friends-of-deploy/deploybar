import Foundation

struct Team: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let slug: String?
    let name: String?
}

struct TeamsResponse: Decodable {
    let teams: [Team]
}
