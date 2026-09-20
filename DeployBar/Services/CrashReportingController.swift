import Foundation

@MainActor
protocol CrashReportingClient: AnyObject {
    func start()
    func stop()
    func discardPendingReports()
}

/// Owns the SDK lifecycle independently of which settings window is visible.
@MainActor
final class CrashReportingController {
    private let client: CrashReportingClient
    private let isAllowed: Bool
    private var isRunning = false

    init(settings: SettingsStore, client: CrashReportingClient? = nil,
         isAllowed: Bool = CrashReportingController.isAllowedInCurrentProcess) {
        self.client = client ?? SentryCrashReportingClient()
        self.isAllowed = isAllowed
        if isAllowed {
            if settings.shareCrashReports {
                self.client.start()
                isRunning = true
            } else {
                self.client.discardPendingReports()
            }
        }
        settings.crashReportingChanged = { [weak self] enabled in
            self?.setEnabled(enabled)
        }
    }

    nonisolated static var isAllowedInCurrentProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["DEPLOYBAR_DEMO"] != "1"
            && environment["XCTestConfigurationFilePath"] == nil
            && NSClassFromString("XCTestCase") == nil
    }

    private func setEnabled(_ enabled: Bool) {
        guard isAllowed, enabled != isRunning else { return }
        if enabled {
            // Only launch with existing consent may send a previous crash.
            // A new grant must never revive reports from a revoked grant.
            client.discardPendingReports()
            client.start()
        } else {
            client.stop()
            client.discardPendingReports()
        }
        isRunning = enabled
    }
}
