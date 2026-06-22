import XCTest
@testable import VercelBar

final class FaviconURLTests: XCTestCase {
    func test_buildsGoogleS2URLFromHost() {
        let u = FaviconURL.forHost("web-app.example.com")
        XCTAssertEqual(u?.absoluteString, "https://www.google.com/s2/favicons?sz=64&domain=web-app.example.com")
    }
    func test_extractsHostFromFullURL() {
        XCTAssertEqual(FaviconURL.forHost("https://dashboard-abc.vercel.app/path")?.absoluteString,
                       "https://www.google.com/s2/favicons?sz=64&domain=dashboard-abc.vercel.app")
    }
    func test_nilForEmptyOrNil() {
        XCTAssertNil(FaviconURL.forHost(nil))
        XCTAssertNil(FaviconURL.forHost(""))
    }

    func test_candidatesTrySiteFaviconFirstThenGoogle() {
        let urls = FaviconURL.candidates(forHost: "web-app.example.com").map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://web-app.example.com/favicon.ico",
            "https://www.google.com/s2/favicons?sz=64&domain=web-app.example.com",
        ])
    }

    func test_candidatesEmptyForNil() {
        XCTAssertTrue(FaviconURL.candidates(forHost: nil).isEmpty)
    }
}

final class BestDomainTests: XCTestCase {
    func test_prefersCustomDomainOverVercelApp() {
        let host = BestDomain.pick(
            url: "web-app-a1b2c3d4-acme.vercel.app",
            aliases: ["web-app.example.com", "web-app-acme.vercel.app",
                      "web-app-git-main-acme.vercel.app"])
        XCTAssertEqual(host, "web-app.example.com")
    }

    func test_prefersCleanVercelAliasOverGeneratedURL() {
        // No custom domain → pick a clean project alias, never the git-branch
        // alias and never the hashed deployment URL.
        let host = BestDomain.pick(
            url: "blog-m3n4o5p6-acme.vercel.app",
            aliases: ["blog-olive.vercel.app", "blog-acme.vercel.app",
                      "blog-git-main-acme.vercel.app"])
        // Shortest clean alias wins; the git-branch alias and the hashed
        // deployment URL are excluded.
        XCTAssertEqual(host, "blog-acme.vercel.app")
        XCTAssertNotEqual(host, "blog-m3n4o5p6-acme.vercel.app")
        XCTAssertFalse(host?.contains("-git-") ?? true)
    }

    func test_fallsBackToURLWhenNoAliases() {
        XCTAssertEqual(BestDomain.pick(url: "x-abc.vercel.app", aliases: []), "x-abc.vercel.app")
    }

    func test_nilWhenNothing() {
        XCTAssertNil(BestDomain.pick(url: nil, aliases: []))
    }
}
