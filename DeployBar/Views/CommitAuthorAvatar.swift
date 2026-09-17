import SwiftUI

/// The commit author's avatar, shown beside a deployment's commit line.
///
/// Reuses `FaviconCache` rather than adding a second image cache: it already
/// does memory + disk caching, PNG re-encoding and HTML-error rejection, and an
/// avatar is the same problem (a small remote image keyed by a stable string).
///
/// When no image resolves — a CLI deploy, a bot, or a git identity with no
/// GitHub account — it falls back to the author's initials on a color derived
/// from their name, so rows stay distinguishable and the left edge stays
/// aligned. See `CommitAuthor` for the URL and initials rules.
struct CommitAuthorAvatar: View {
    let login: String?
    /// Provider-supplied avatar URL, used ahead of the login-derived one.
    var avatarURL: String? = nil
    /// Who triggered the deploy, used only when there is no commit author.
    var creatorUsername: String? = nil
    var size: CGFloat = 16

    @State private var image: NSImage?

    private var name: String? {
        CommitAuthor.displayName(login: login, creator: creatorUsername)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                initialsFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // A hairline ring keeps a light avatar from bleeding into the row
        // background; at 16pt a heavier border would eat the face.
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .task(id: CommitAuthor.imageURL(login: login, avatarURL: avatarURL)?.absoluteString) {
            guard let url = CommitAuthor.imageURL(login: login, avatarURL: avatarURL) else {
                image = nil
                return
            }
            image = await FaviconCache.shared.image(for: nil, directURL: url.absoluteString)
        }
        // The face alone rarely identifies someone, and initials never do.
        .tooltip(name ?? String(localized: "Unknown author", comment: "Avatar tooltip when no author is known"))
        .accessibilityLabel(Text(name.map { String(localized: "Commit by \($0)", comment: "Avatar accessibility label") }
            ?? String(localized: "Unknown commit author", comment: "Avatar accessibility label")))
    }

    private var initialsFallback: some View {
        ZStack {
            CommitAuthor.color(for: name)
            if let initials = CommitAuthor.initials(for: name) {
                Text(initials)
                    // Scales with the avatar so the two stay in proportion if the
                    // row's sizing ever changes.
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

/// Pure rules for turning a commit author into an avatar URL, initials and a
/// fallback color. Kept free of SwiftUI so they can be unit-tested directly.
enum CommitAuthor {
    /// Best available display name: the commit's author, else whoever triggered
    /// the deploy, else nothing.
    static func displayName(login: String?, creator: String?) -> String? {
        for candidate in [login, creator] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// The avatar to fetch: a provider-supplied URL when there is one, else
    /// GitHub's `github.com/<login>.png`, which needs no API call or token.
    ///
    /// Only a real GitHub login gets the derived URL. A raw git author name
    /// (`"Konrad Alfaro"`) is not a username, and asking for it would 404 on
    /// every poll — those fall through to initials instead.
    static func imageURL(login: String?, avatarURL: String?) -> URL? {
        if let avatarURL, !avatarURL.isEmpty, let url = URL(string: avatarURL) { return url }
        guard let login = normalizedLogin(login) else { return nil }
        return URL(string: "https://github.com/\(login).png?size=64")
    }

    /// A GitHub login if the string can be one: letters, digits and hyphens.
    /// Rejects the display names and emails that land in the same field.
    static func normalizedLogin(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= 39,          // GitHub's own username length cap
              !trimmed.hasPrefix("-"),
              !trimmed.hasSuffix("-"),
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return trimmed
    }

    /// One or two uppercase letters: initials from a "First Last" name, else the
    /// leading letters of a single token (`octocat` → `OC`).
    static func initials(for name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        // Split on the separators that appear in logins and git names alike.
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .filter { $0.contains(where: \.isLetter) }

        if words.count >= 2 {
            let first = words[0].first(where: \.isLetter)
            let second = words[1].first(where: \.isLetter)
            if let first, let second { return "\(first)\(second)".uppercased() }
        }
        let letters = (words.first ?? Substring(name)).filter(\.isLetter)
        guard !letters.isEmpty else { return nil }
        return String(letters.prefix(2)).uppercased()
    }

    /// Stable color for a name, so the same author keeps the same chip between
    /// launches. Hashing Swift's `hashValue` would not — it is seeded per
    /// process — so this sums the scalars instead.
    static func color(for name: String?) -> Color {
        guard let name, !name.isEmpty else { return Color.gray }
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return ScopeColor.color(at: sum % ScopeColor.palette.count)
    }
}
