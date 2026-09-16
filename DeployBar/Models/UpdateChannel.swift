import Foundation

/// Which stream of releases this install follows.
///
/// Stored as a bare string in `UserDefaults`, so `from(storedValue:)` is the
/// only supported way in: anything unrecognised means stable, which is the
/// channel a user who never opened the Updates tab expects to be on.
enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case beta

    var id: String { rawValue }

    static func from(storedValue: String?) -> UpdateChannel {
        guard let storedValue, let channel = UpdateChannel(rawValue: storedValue) else {
            return .stable
        }
        return channel
    }

    /// The feed Sparkle reads for this channel. Both are published from the
    /// repository's `gh-pages` branch; a stable release is written to both
    /// files, a beta release only to the beta one.
    var appcastURL: URL {
        switch self {
        case .stable:
            return URL(string: "https://friends-of-deploy.github.io/deploybar/appcast.xml")!
        case .beta:
            return URL(string: "https://friends-of-deploy.github.io/deploybar/appcast-beta.xml")!
        }
    }

    var title: String {
        switch self {
        case .stable:
            return String(localized: "Stable", comment: "Update channel name")
        case .beta:
            return String(localized: "Beta", comment: "Update channel name")
        }
    }
}
