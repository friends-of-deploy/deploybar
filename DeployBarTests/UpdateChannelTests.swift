import XCTest
@testable import DeployBar

/// The channel is persisted as a bare string, so a value written by an older
/// build — or by a user poking at `defaults write` — has to land somewhere
/// safe. These pin that "somewhere safe" is always stable.
final class UpdateChannelTests: XCTestCase {
    func test_rawValuesAreStableStorageKeys() {
        XCTAssertEqual(UpdateChannel.stable.rawValue, "stable")
        XCTAssertEqual(UpdateChannel.beta.rawValue, "beta")
    }

    func test_roundTripsThroughRawValue() {
        for channel in UpdateChannel.allCases {
            XCTAssertEqual(UpdateChannel(rawValue: channel.rawValue), channel)
        }
    }

    func test_unknownStoredValueFallsBackToStable() {
        XCTAssertEqual(UpdateChannel.from(storedValue: "nightly"), .stable)
        XCTAssertEqual(UpdateChannel.from(storedValue: ""), .stable)
        XCTAssertEqual(UpdateChannel.from(storedValue: nil), .stable)
    }

    func test_knownStoredValueIsHonoured() {
        XCTAssertEqual(UpdateChannel.from(storedValue: "beta"), .beta)
        XCTAssertEqual(UpdateChannel.from(storedValue: "stable"), .stable)
    }

    /// A typo in a feed URL is invisible until a release fails to reach anyone,
    /// so the exact strings are pinned here.
    func test_appcastURLs() {
        XCTAssertEqual(UpdateChannel.stable.appcastURL.absoluteString,
                       "https://friends-of-deploy.github.io/deploybar/appcast.xml")
        XCTAssertEqual(UpdateChannel.beta.appcastURL.absoluteString,
                       "https://friends-of-deploy.github.io/deploybar/appcast-beta.xml")
    }

    func test_channelsDoNotShareAFeed() {
        let urls = UpdateChannel.allCases.map(\.appcastURL)
        XCTAssertEqual(Set(urls).count, urls.count)
    }

    func test_everyChannelHasADistinctNonEmptyTitle() {
        let titles = UpdateChannel.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "channels must not share a title")
        XCTAssertFalse(titles.contains(where: \.isEmpty))
    }
}
