import Foundation

struct VercelUser: Decodable, Equatable, Sendable {
    let username: String
    let name: String?
    let email: String?
    let avatar: String?
}

struct UserResponse: Decodable {
    let user: VercelUser
}
