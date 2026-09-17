import XCTest
import SwiftUI
@testable import DeployBar

/// The commit-author avatar's pure rules: which string is a real GitHub login
/// (and therefore has a derivable avatar), and what the initials fallback shows
/// when it isn't.
final class CommitAuthorTests: XCTestCase {

    // MARK: - Login validation

    func test_acceptsRealLogins() {
        XCTAssertEqual(CommitAuthor.normalizedLogin("octocat"), "octocat")
        XCTAssertEqual(CommitAuthor.normalizedLogin("konrad-8lines"), "konrad-8lines")
        XCTAssertEqual(CommitAuthor.normalizedLogin("user123"), "user123")
        XCTAssertEqual(CommitAuthor.normalizedLogin("  octocat  "), "octocat",
                       "Surrounding whitespace shouldn't disqualify a login")
    }

    /// The same Vercel/GitHub field carries display names and emails, and asking
    /// github.com for those 404s on every single poll.
    func test_rejectsNonLogins() {
        XCTAssertNil(CommitAuthor.normalizedLogin("Konrad Alfaro"), "A display name has a space")
        XCTAssertNil(CommitAuthor.normalizedLogin("dev@example.com"), "An email is not a login")
        XCTAssertNil(CommitAuthor.normalizedLogin(""))
        XCTAssertNil(CommitAuthor.normalizedLogin("   "))
        XCTAssertNil(CommitAuthor.normalizedLogin(nil))
        XCTAssertNil(CommitAuthor.normalizedLogin("-leading"), "GitHub logins can't start with a hyphen")
        XCTAssertNil(CommitAuthor.normalizedLogin("trailing-"), "GitHub logins can't end with a hyphen")
        XCTAssertNil(CommitAuthor.normalizedLogin(String(repeating: "a", count: 40)),
                     "Past GitHub's 39-character cap")
    }

    // MARK: - Avatar URL

    func test_prefersProviderSuppliedAvatar() {
        let url = CommitAuthor.imageURL(login: "octocat",
                                        avatarURL: "https://avatars.githubusercontent.com/u/583231")
        XCTAssertEqual(url?.absoluteString, "https://avatars.githubusercontent.com/u/583231",
                       "A real avatar URL beats the derived one")
    }

    func test_derivesAvatarFromLogin() {
        let url = CommitAuthor.imageURL(login: "octocat", avatarURL: nil)
        XCTAssertEqual(url?.absoluteString, "https://github.com/octocat.png?size=64")
    }

    /// Vercel's meta gives a login but no avatar; a git-only identity gives
    /// neither, and must fall through to initials rather than a doomed request.
    func test_noURLForNonLoginAuthors() {
        XCTAssertNil(CommitAuthor.imageURL(login: "Konrad Alfaro", avatarURL: nil))
        XCTAssertNil(CommitAuthor.imageURL(login: nil, avatarURL: nil))
        XCTAssertNil(CommitAuthor.imageURL(login: nil, avatarURL: ""))
    }

    // MARK: - Display name

    func test_fallsBackToDeployCreator() {
        XCTAssertEqual(CommitAuthor.displayName(login: "author", creator: "deployer"), "author")
        XCTAssertEqual(CommitAuthor.displayName(login: nil, creator: "deployer"), "deployer",
                       "A CLI deploy has no commit author, only a creator")
        XCTAssertEqual(CommitAuthor.displayName(login: "  ", creator: "deployer"), "deployer",
                       "Blank is as good as absent")
        XCTAssertNil(CommitAuthor.displayName(login: nil, creator: nil))
    }

    // MARK: - Initials

    func test_initialsFromFullName() {
        XCTAssertEqual(CommitAuthor.initials(for: "Konrad Alfaro"), "KA")
        XCTAssertEqual(CommitAuthor.initials(for: "konrad alfaro"), "KA")
        XCTAssertEqual(CommitAuthor.initials(for: "Ada Lovelace Byron"), "AL",
                       "Two initials, not three")
    }

    /// Logins are one token, so they take their first two letters instead.
    func test_initialsFromSingleToken() {
        XCTAssertEqual(CommitAuthor.initials(for: "octocat"), "OC")
        XCTAssertEqual(CommitAuthor.initials(for: "k"), "K")
    }

    /// Hyphens and dots separate words in logins the way spaces do in names.
    func test_initialsAcrossSeparators() {
        XCTAssertEqual(CommitAuthor.initials(for: "konrad-8lines"), "KL",
                       "Skips the digit to reach the second word's letter")
        XCTAssertEqual(CommitAuthor.initials(for: "jane.doe"), "JD")
        XCTAssertEqual(CommitAuthor.initials(for: "jane_doe"), "JD")
    }

    func test_noInitialsWithoutLetters() {
        XCTAssertNil(CommitAuthor.initials(for: "123"), "Digits fall back to the person glyph")
        XCTAssertNil(CommitAuthor.initials(for: ""))
        XCTAssertNil(CommitAuthor.initials(for: "   "))
        XCTAssertNil(CommitAuthor.initials(for: nil))
    }

    // MARK: - Fallback color

    /// The color is drawn from the name, so the same author keeps the same chip
    /// across launches — `hashValue` would not, being seeded per process.
    func test_colorIsStableForAName() {
        XCTAssertEqual(CommitAuthor.color(for: "octocat"), CommitAuthor.color(for: "octocat"))
        XCTAssertEqual(CommitAuthor.color(for: nil), Color.gray)
    }

    func test_colorStaysInPalette() {
        for name in ["a", "octocat", "Konrad Alfaro", "zzzzzzzzzzzzzzzzzzzz", "日本語"] {
            XCTAssertTrue(ScopeColor.palette.contains(CommitAuthor.color(for: name)),
                          "\(name) produced a color outside the palette")
        }
    }
}

/// Decoding and caching of the commit-author fields the avatar reads.
final class CommitAuthorDecodingTests: XCTestCase {

    /// Vercel reports the author's login under `meta`, but never an avatar URL.
    func test_decodesVercelCommitAuthorLogin() throws {
        let json = """
        {"deployments":[{"uid":"dpl_x","name":"app","state":"READY","url":"app.vercel.app",
        "createdAt":1700000000000,"meta":{"githubCommitAuthorLogin":"octocat",
        "githubCommitSha":"abc123","githubCommitRef":"main"}}]}
        """
        let d = try JSONDecoder().decode(DeploymentsResponse.self, from: Data(json.utf8)).deployments[0]
        XCTAssertEqual(d.commitAuthorLogin, "octocat")
        XCTAssertNil(d.commitAuthorAvatarURL, "Vercel supplies no avatar; it's derived from the login")
        XCTAssertEqual(CommitAuthor.imageURL(login: d.commitAuthorLogin,
                                             avatarURL: d.commitAuthorAvatarURL)?.absoluteString,
                       "https://github.com/octocat.png?size=64")
    }

    func test_authorFieldsAreOptional() throws {
        let json = """
        {"deployments":[{"uid":"dpl_x","name":"manual","state":"READY","url":"m.vercel.app","createdAt":1}]}
        """
        let d = try JSONDecoder().decode(DeploymentsResponse.self, from: Data(json.utf8)).deployments[0]
        XCTAssertNil(d.commitAuthorLogin)
        XCTAssertNil(d.commitAuthorAvatarURL)
    }

    /// The cache rebuilds rows through the memberwise init; a field missed there
    /// would blank every avatar on relaunch until the first poll landed.
    func test_cacheRoundTripsAuthorFields() throws {
        let account = Account.vercelCLI(id: UUID(), label: "acct")
        let deployment = Deployment(
            uid: "dpl_1", name: "app", stateRaw: "READY", url: "app.vercel.app",
            createdAt: 1700000000000, creatorUsername: "deployer",
            commitAuthorLogin: "octocat",
            commitAuthorAvatarURL: "https://avatars.githubusercontent.com/u/583231")
        let sourced = SourcedDeployment(deployment: deployment, account: account, teamId: nil)

        let cached = RowCache.CachedDeployment(sourced)
        let data = try JSONEncoder().encode(cached)
        let decoded = try JSONDecoder().decode(RowCache.CachedDeployment.self, from: data)
        let restored = try XCTUnwrap(decoded.restore(accounts: [account.id: account]))

        XCTAssertEqual(restored.deployment.commitAuthorLogin, "octocat")
        XCTAssertEqual(restored.deployment.commitAuthorAvatarURL,
                       "https://avatars.githubusercontent.com/u/583231")
    }
}
