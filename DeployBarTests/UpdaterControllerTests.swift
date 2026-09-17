import XCTest
@testable import DeployBar

/// `UpdaterController` owns a live Sparkle updater, so what is worth pinning
/// here is the pure part: the feed string the delegate hands Sparkle, which is
/// the thing that decides whether a tester ever sees a beta build.
@MainActor
final class UpdaterFeedSelectionTests: XCTestCase {
    func test_feedStringMatchesTheChannelsAppcast() {
        XCTAssertEqual(UpdaterController.feedURLString(for: .stable),
                       UpdateChannel.stable.appcastURL.absoluteString)
        XCTAssertEqual(UpdaterController.feedURLString(for: .beta),
                       UpdateChannel.beta.appcastURL.absoluteString)
    }

    func test_channelsResolveToDifferentFeeds() {
        XCTAssertNotEqual(UpdaterController.feedURLString(for: .stable),
                          UpdaterController.feedURLString(for: .beta))
    }

    /// The setter must write through to the injected `SettingsStore` rather
    /// than caching the channel locally, so `settings` stays the single
    /// source of truth the delegate reads from on every check.
    @MainActor
    func test_channelSetterPersistsThroughSettings() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = UpdaterController(settings: settings)

        XCTAssertEqual(controller.channel, .stable)

        controller.channel = .beta

        XCTAssertEqual(controller.channel, .beta)
        XCTAssertEqual(settings.updateChannel, .beta, "the setter must write through to storage")
    }

    @MainActor
    func test_initialChannelIsReadFromSettings() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.updateChannel = .beta

        XCTAssertEqual(UpdaterController(settings: settings).channel, .beta)
    }

    /// The delegate is asked for a feed on every check, so a channel switch
    /// has to be visible immediately — no restart, no cached URL. This
    /// exercises the actual `SPUUpdaterDelegate` conformance, not just the
    /// pure mapping function, so it is the one test that would catch the
    /// delegate reading a stale or wrong source of truth.
    @MainActor
    func test_delegateFeedURLStringReflectsCurrentChannel() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = UpdaterController(settings: settings)

        controller.channel = .beta
        XCTAssertEqual(controller.feedURLString(for: controller.updater),
                       UpdateChannel.beta.appcastURL.absoluteString)

        controller.channel = .stable
        XCTAssertEqual(controller.feedURLString(for: controller.updater),
                       UpdateChannel.stable.appcastURL.absoluteString)
    }
}
