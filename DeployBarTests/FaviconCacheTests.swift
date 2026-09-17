import XCTest
import AppKit
@testable import DeployBar

/// The popover redraws these icons constantly — every scroll, every poll, every
/// reopen. What matters is not the first fetch but how many times the *same*
/// image is fetched again.
final class FaviconCacheTests: XCTestCase {

    // MARK: - Stub transport

    /// Counts requests per URL and serves canned responses.
    final class StubProtocol: URLProtocol {
        struct Response {
            var status: Int = 200
            var data: Data
            var contentType: String? = "image/png"
        }

        nonisolated(unsafe) private static let lock = NSLock()
        nonisolated(unsafe) private static var routes: [String: Response] = [:]
        nonisolated(unsafe) private static var counts: [String: Int] = [:]

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            routes = [:]; counts = [:]
        }
        static func route(_ url: String, _ response: Response) {
            lock.lock(); defer { lock.unlock() }
            routes[url] = response
        }
        static func count(_ url: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[url] ?? 0
        }
        /// Total requests across every URL, for "did it touch the network at all".
        static var totalRequests: Int {
            lock.lock(); defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let key = request.url?.absoluteString ?? ""
            Self.lock.lock()
            Self.counts[key, default: 0] += 1
            let route = Self.routes[key]
            Self.lock.unlock()

            guard let route else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            var headers: [String: String] = [:]
            if let type = route.contentType { headers["Content-Type"] = type }
            let response = HTTPURLResponse(url: request.url!, statusCode: route.status,
                                           httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: route.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    /// A real PNG, so `NSImage(data:)` accepts it.
    private func pngData(size: CGFloat) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemBlue.drawSwatch(in: NSRect(x: 0, y: 0, width: size, height: size))
        image.unlockFocus()
        return image.pngData()!
    }

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("favicon-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeCache(ttl: TimeInterval = FaviconCache.defaultTTL,
                           now: @escaping () -> Date = Date.init) -> FaviconCache {
        FaviconCache(session: makeSession(), directory: tempDir, ttl: ttl, now: now)
    }

    // MARK: - Hits

    func test_secondLookupOfTheSameHostDoesNotRefetch() async {
        let url = "https://example.com/favicon.ico"
        StubProtocol.route(url, .init(data: pngData(size: 32)))
        let cache = makeCache()

        let first = await cache.image(for: "example.com")
        let second = await cache.image(for: "example.com")

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(StubProtocol.count(url), 1, "the second lookup must come from cache")
    }

    /// A relaunch: a brand-new cache instance over the same directory.
    func test_aFreshCacheReadsTheImageFromDiskInsteadOfRefetching() async {
        let url = "https://example.com/favicon.ico"
        StubProtocol.route(url, .init(data: pngData(size: 32)))

        let first = makeCache()
        let fromNetwork = await first.image(for: "example.com")
        XCTAssertNotNil(fromNetwork)
        XCTAssertEqual(StubProtocol.count(url), 1)

        let second = makeCache()
        let fromDisk = await second.image(for: "example.com")
        XCTAssertNotNil(fromDisk, "a relaunch should paint from disk")
        XCTAssertEqual(StubProtocol.count(url), 1, "no refetch after relaunch")
    }

    // MARK: - Misses

    /// The main gap: a project with no favicon re-walked every candidate on every
    /// single row appearance, and a dead host does not fail fast.
    func test_aHostWithNoFaviconIsOnlyAttemptedOnce() async {
        // Both candidates fail: own domain 404s, Google returns an HTML error.
        let own = "https://nope.example/favicon.ico"
        let google = "https://www.google.com/s2/favicons?sz=64&domain=nope.example"
        StubProtocol.route(own, .init(status: 404, data: Data("nope".utf8)))
        StubProtocol.route(google, .init(status: 200, data: Data("<html>".utf8),
                                         contentType: "text/html"))
        let cache = makeCache()

        for attempt in 1...3 {
            let result = await cache.image(for: "nope.example")
            XCTAssertNil(result, "attempt \(attempt) should resolve to nothing")
        }

        XCTAssertEqual(StubProtocol.count(own), 1, "a remembered miss must not retry the host")
        XCTAssertEqual(StubProtocol.count(google), 1, "nor the fallback service")
    }

    func test_aRememberedMissSurvivesRelaunch() async {
        let own = "https://nope.example/favicon.ico"
        StubProtocol.route(own, .init(status: 404, data: Data()))

        let first = makeCache()
        _ = await first.image(for: "nope.example")
        let afterFirst = StubProtocol.totalRequests

        let second = makeCache()
        let result = await second.image(for: "nope.example")
        XCTAssertNil(result)
        XCTAssertEqual(StubProtocol.totalRequests, afterFirst,
                       "a miss recorded on disk must not be re-walked after relaunch")
    }

    /// A miss must not be permanent — a site that gains a favicon should show it.
    func test_aMissIsRetriedOnceItsShortTTLPasses() async {
        let own = "https://later.example/favicon.ico"
        StubProtocol.route(own, .init(status: 404, data: Data()))

        var clock = Date()
        let cache = makeCache(now: { clock })
        let missed = await cache.image(for: "later.example")
        XCTAssertNil(missed)

        // The site gains a favicon, and enough time passes for the miss to lapse.
        StubProtocol.route(own, .init(data: pngData(size: 32)))
        clock = clock.addingTimeInterval(FaviconCache.missTTL + 60)

        let fresh = FaviconCache(session: makeSession(), directory: tempDir, now: { clock })
        let retried = await fresh.image(for: "later.example")
        XCTAssertNotNil(retried, "an expired miss must be retried")
    }

    // MARK: - Expiry

    func test_anExpiredImageIsRefetched() async {
        let url = "https://example.com/favicon.ico"
        StubProtocol.route(url, .init(data: pngData(size: 32)))

        var clock = Date()
        let cache = makeCache(now: { clock })
        let initial = await cache.image(for: "example.com")
        XCTAssertNotNil(initial)
        XCTAssertEqual(StubProtocol.count(url), 1)

        clock = clock.addingTimeInterval(FaviconCache.defaultTTL + 60)
        let fresh = FaviconCache(session: makeSession(), directory: tempDir,
                                 ttl: FaviconCache.defaultTTL, now: { clock })
        let refetched = await fresh.image(for: "example.com")
        XCTAssertNotNil(refetched)
        XCTAssertEqual(StubProtocol.count(url), 2, "a stale icon must be refetched")
    }

    func test_anImageWithinItsTTLIsNotRefetched() async {
        let url = "https://example.com/favicon.ico"
        StubProtocol.route(url, .init(data: pngData(size: 32)))

        var clock = Date()
        let cache = makeCache(now: { clock })
        let initial = await cache.image(for: "example.com")
        XCTAssertNotNil(initial)

        clock = clock.addingTimeInterval(FaviconCache.defaultTTL / 2)
        let fresh = FaviconCache(session: makeSession(), directory: tempDir,
                                 ttl: FaviconCache.defaultTTL, now: { clock })
        let stillCached = await fresh.image(for: "example.com")
        XCTAssertNotNil(stillCached, "a fresh icon must come from disk")
        XCTAssertEqual(StubProtocol.count(url), 1, "a fresh icon must come from disk")
    }

    // MARK: - Downscaling

    func test_oversizedImagesAreStoredAtIconSize() async {
        let url = "https://avatars.example/u/1"
        StubProtocol.route(url, .init(data: pngData(size: 512)))
        let cache = makeCache()

        let image = await cache.image(for: nil, directURL: url)
        let longest = max(image?.size.width ?? 0, image?.size.height ?? 0)
        XCTAssertLessThanOrEqual(longest, FaviconCache.maxPixelSize,
                                 "a 512pt avatar has no business in a 16pt slot")
    }

    func test_smallImagesAreNotUpscaled() {
        let small = NSImage(size: NSSize(width: 16, height: 16))
        let result = small.downscaled(toFit: FaviconCache.maxPixelSize)
        XCTAssertEqual(result.size, NSSize(width: 16, height: 16),
                       "upscaling a small favicon would only cost bytes")
    }

    func test_downscalingPreservesAspectRatio() {
        let wide = NSImage(size: NSSize(width: 200, height: 100))
        let result = wide.downscaled(toFit: 64)
        XCTAssertEqual(result.size, NSSize(width: 64, height: 32))
    }

    // MARK: - Fallback order

    func test_googleFallbackIsUsedWhenTheSiteHasNoFavicon() async {
        let own = "https://example.com/favicon.ico"
        let google = "https://www.google.com/s2/favicons?sz=64&domain=example.com"
        StubProtocol.route(own, .init(status: 404, data: Data()))
        StubProtocol.route(google, .init(data: pngData(size: 32)))
        let cache = makeCache()

        let viaFallback = await cache.image(for: "example.com")
        XCTAssertNotNil(viaFallback)
        XCTAssertEqual(StubProtocol.count(google), 1)
    }
}
