import Foundation
import Observation
import Sparkle

/// The app's one point of contact with Sparkle.
///
/// Two jobs. First, translation: `SPUUpdater` publishes `canCheckForUpdates`
/// and `lastUpdateCheckDate` through KVO, which SwiftUI's Observation does not
/// see, so this class observes them and republishes them as observable state.
/// Second, routing: as the updater's delegate it answers `feedURLString(for:)`
/// with the current channel's appcast, so switching channels takes effect on
/// the next check without a relaunch.
///
/// Sparkle's own preferences — automatic checks, automatic downloads, last
/// check time — stay in Sparkle's hands in the standard defaults domain. This
/// class forwards to them rather than storing its own copies.
@MainActor
@Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?

    /// Bumped whenever a preference that lives in Sparkle changes, so
    /// Observation has a stored property to key the forwarders off.
    private var _didChange = 0

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()

        // `startingUpdater: true` hands the background schedule to Sparkle, so
        // the app needs no timer of its own.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)

        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate

        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastUpdateCheckDate = updater.lastUpdateCheckDate }
            },
        ]
    }

    // MARK: - Preferences

    /// Forwarded to Sparkle, which is the store of record for these.
    ///
    /// `@Observable` only tracks stored properties, so a computed forwarder
    /// needs an explicit `access` / `withMutation` pair — keyed off the
    /// `_didChange` counter — to notify SwiftUI that the value moved.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \._didChange)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \._didChange) {
                controller.updater.automaticallyChecksForUpdates = newValue
                _didChange &+= 1
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \._didChange)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \._didChange) {
                controller.updater.automaticallyDownloadsUpdates = newValue
                _didChange &+= 1
            }
        }
    }

    /// The release stream this install follows. Setting it persists the choice
    /// and checks straight away, so the user sees the effect of the switch
    /// rather than waiting for the next scheduled check.
    var channel: UpdateChannel {
        get {
            access(keyPath: \._didChange)
            return settings.updateChannel
        }
        set {
            guard newValue != settings.updateChannel else { return }
            withMutation(keyPath: \._didChange) {
                settings.updateChannel = newValue
                _didChange &+= 1
            }
            checkForUpdates()
        }
    }

    // MARK: - Actions

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    /// Exposed so tests can exercise `feedURLString(for:)` against a real
    /// `SPUUpdater` without widening the delegate API itself.
    var updater: SPUUpdater { controller.updater }

    nonisolated static func feedURLString(for channel: UpdateChannel) -> String {
        channel.appcastURL.absoluteString
    }

    /// `SPUUpdaterDelegate` is declared `NS_SWIFT_UI_ACTOR`, so this is called
    /// on the main actor — reading the injected `settings` directly is safe
    /// and keeps this controller's single source of truth for the channel.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedURLString(for: settings.updateChannel)
    }
}
