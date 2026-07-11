import Foundation

enum Provider: String, Codable, CaseIterable, Sendable {
    case vercel
    case github
    case azureDevOps

    var displayName: String {
        switch self {
        case .vercel:      return "Vercel"
        case .github:      return "GitHub"
        case .azureDevOps: return "Azure DevOps"
        }
    }

    /// SF Symbol used in the dropdown/badges. (No brand symbols ship with SF; use neutral glyphs.)
    var iconName: String {
        switch self {
        case .vercel:      return "triangle.fill"
        case .github:      return "chevron.left.forwardslash.chevron.right"
        case .azureDevOps: return "cloud.fill"
        }
    }

    /// Whether a working client exists for this provider.
    var isImplemented: Bool {
        switch self {
        case .vercel, .github: return true
        case .azureDevOps:     return false
        }
    }
}
