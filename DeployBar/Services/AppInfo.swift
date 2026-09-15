import Foundation

/// The app's identity as shown in settings: version numbers from the bundle,
/// and the maker's contact points.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static let websiteLabel = "8lines.io"
    static let websiteURL = URL(string: "https://8lines.io")!
    static let githubLabel = "friends-of-deploy/deploybar"
    static let githubURL = URL(string: "https://github.com/friends-of-deploy/deploybar")!
    static let contactURL = URL(string: "mailto:konrad+deploybar@8lines.io")!
}
