import XCTest
@testable import DeployBar

/// `UpdaterController` owns a live Sparkle updater, so what is worth pinning
/// here is the pure part: the feed string the delegate hands Sparkle, which is
/// the thing that decides whether a tester ever sees a beta build.
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

    /// The delegate is asked for a feed on every check, so a channel switch has
    /// to be visible immediately — no restart, no cached URL.
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
}
