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

    /// Monochrome SVG template asset shared by menus and account views.
    var iconAssetName: String {
        switch self {
        case .vercel:      return "ProviderVercel"
        case .github:      return "ProviderGitHub"
        case .azureDevOps: return "ProviderAzureDevOps"
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
