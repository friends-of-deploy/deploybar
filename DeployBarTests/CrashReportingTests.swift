import XCTest
import Observation
import Sentry
@testable import DeployBar

@MainActor
final class CrashReportingTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "DeployBarTests.CrashReporting.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func test_noConsentDoesNotStartSDKAndDiscardsOldReports() {
        let settings = SettingsStore(defaults: defaults)
        let client = RecordingCrashClient()
        let controller = CrashReportingController(settings: settings, client: client, isAllowed: true)
        XCTAssertFalse(settings.shareCrashReports)
        XCTAssertEqual(client.actions, ["discard"])
        withExtendedLifetime(controller) {}
    }

    func test_consentStartsImmediatelyAndRevocationStopsBeforeDiscarding() {
        let settings = SettingsStore(defaults: defaults)
        let client = RecordingCrashClient()
        let controller = CrashReportingController(settings: settings, client: client, isAllowed: true)
        settings.shareCrashReports = true
        settings.shareCrashReports = true
        XCTAssertEqual(client.actions, ["discard", "discard", "start"])
        XCTAssertTrue(SettingsStore(defaults: defaults).shareCrashReports)

        settings.shareCrashReports = false
        XCTAssertEqual(client.actions.suffix(2), ["stop", "discard"])
        XCTAssertFalse(SettingsStore(defaults: defaults).shareCrashReports)
        withExtendedLifetime(controller) {}
    }

    func test_relaunchWithConsentPreservesPendingCrashReport() {
        SettingsStore(defaults: defaults).shareCrashReports = true
        let client = RecordingCrashClient()
        let controller = CrashReportingController(settings: SettingsStore(defaults: defaults),
                                                  client: client, isAllowed: true)
        XCTAssertEqual(client.actions, ["start"])
        withExtendedLifetime(controller) {}
    }

    func test_demoAndTestProcessesCannotStartSDKEvenWithConsent() {
        let settings = SettingsStore(defaults: defaults)
        settings.shareCrashReports = true
        let client = RecordingCrashClient()
        let controller = CrashReportingController(settings: settings, client: client, isAllowed: false)
        settings.shareCrashReports = false
        settings.shareCrashReports = true
        XCTAssertTrue(client.actions.isEmpty)
        withExtendedLifetime(controller) {}
    }

    func test_consentChangesNotifyBothViewsThroughObservation() {
        let settings = SettingsStore(defaults: defaults)
        let changed = expectation(description: "Consent change observed")
        withObservationTracking { _ = settings.shareCrashReports } onChange: { changed.fulfill() }
        settings.shareCrashReports = true
        wait(for: [changed], timeout: 1)
    }

    func test_revocationDropsInFlightEventsEvenAfterAnotherGrant() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let consent = CrashReportConsent()
        let options = SentryCrashReportingClient.options(cacheDirectory: URL(fileURLWithPath: "/tmp/unused"),
                                                         session: session, consent: consent)
        let filter = try XCTUnwrap(options.beforeSend)
        XCTAssertNotNil(filter(Event(level: .fatal)))
        consent.revoke()
        let newConsent = CrashReportConsent()
        XCTAssertTrue(newConsent.isGranted)
        XCTAssertNil(filter(Event(level: .fatal)))
    }

    func test_newGrantRejectsAnOldNativeCrashDeliveredToTheNewSDK() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let options = SentryCrashReportingClient.options(cacheDirectory: URL(fileURLWithPath: "/tmp/unused"),
                                                         session: session, consent: CrashReportConsent())
        let oldCrash = Event(level: .fatal)
        oldCrash.timestamp = Date(timeIntervalSinceNow: -60)
        XCTAssertNil(try XCTUnwrap(options.beforeSend)(oldCrash))
    }

    func test_discardRemovesOnlyTheDedicatedCrashCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let crashCache = directory.appendingPathComponent("CrashReports")
        try FileManager.default.createDirectory(at: crashCache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let otherFile = directory.appendingPathComponent("other-cache")
        try Data("keep".utf8).write(to: otherFile)
        try Data("pending report".utf8).write(to: crashCache.appendingPathComponent("report"))
        SentryCrashReportingClient(cacheDirectory: crashCache).discardPendingReports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashCache.path))
        XCTAssertEqual(try Data(contentsOf: otherFile), Data("keep".utf8))
    }

    func test_regrantIsolatesLateWritesAndRelaunchPreservesOnlyCurrentGrant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CrashReportCache(directory: directory)
        let previous = try cache.prepare()
        try cache.discard()
        let current = try cache.prepare()
        XCTAssertNotEqual(previous.id, current.id)

        // Simulate the SDK's old asynchronous queue writing after close().
        let staleDirectory = cache.directory(for: previous)
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        try Data("old envelope".utf8).write(to: staleDirectory.appendingPathComponent("report"))
        let relaunched = CrashReportCache(directory: directory)
        let restored = try relaunched.prepare()
        XCTAssertEqual(restored.id, current.id)
        XCTAssertEqual(restored.startedAt, current.startedAt)
        XCTAssertNotEqual(relaunched.directory(for: restored), staleDirectory)
    }

    func test_existingConsentAcceptsCrashFromBeforeRelaunch() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let consent = CrashReportConsent(notBefore: Date(timeIntervalSinceNow: -120))
        let options = SentryCrashReportingClient.options(cacheDirectory: URL(fileURLWithPath: "/tmp/unused"),
                                                         session: session, consent: consent)
        let crash = Event(level: .fatal)
        crash.timestamp = Date(timeIntervalSinceNow: -60)
        XCTAssertNotNil(try XCTUnwrap(options.beforeSend)(crash))
    }

    func test_reportRemovesPrivateContentButPreservesSymbolication() throws {
        let event = Event(level: .fatal)
        event.user = User(userId: "private-account")
        event.message = SentryMessage(formatted: "secret-token")
        event.extra = ["log": "secret-token"]
        event.tags = ["repo": "private-repository"]
        event.context = ["os": ["name": "macOS", "version": "14.0"],
                         "app": ["app_version": "1.2.3", "app_name": "private-name"],
                         "custom": ["token": "secret-token"]]
        let frame = Frame()
        frame.package = "/Users/private-user/Applications/DeployBar.app/Contents/MacOS/DeployBar"
        frame.instructionAddress = "0x1234"
        frame.vars = ["token": "secret-token"]
        frame.contextLine = "private-source"
        let stack = SentryStacktrace(frames: [frame], registers: [:])
        let exception = Exception(value: "secret-token", type: "EXC_BAD_ACCESS")
        exception.stacktrace = stack
        event.exceptions = [exception]
        let debug = DebugMeta()
        debug.codeFile = frame.package
        debug.debugID = "01234567-89AB-CDEF-0123-456789ABCDEF"
        event.debugMeta = [debug]

        let clean = SentryCrashReportingClient.sanitize(event)
        let payload = try JSONSerialization.data(withJSONObject: clean.serialize(), options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: payload, encoding: .utf8))
        for forbidden in ["secret-token", "private-account", "private-repository", "private-user", "private-source", "private-name"] {
            XCTAssertFalse(json.contains(forbidden), "Leaked \(forbidden)")
        }
        XCTAssertEqual(clean.exceptions?.first?.type, "EXC_BAD_ACCESS")
        XCTAssertEqual(clean.exceptions?.first?.stacktrace?.frames.first?.instructionAddress, "0x1234")
        XCTAssertEqual(clean.debugMeta?.first?.debugID, debug.debugID)
        XCTAssertEqual(clean.debugMeta?.first?.codeFile, "DeployBar")
        XCTAssertEqual(clean.context?["os"]?["version"] as? String, "14.0")
    }
}

@MainActor
private final class RecordingCrashClient: CrashReportingClient {
    var actions: [String] = []
    func start() { actions.append("start") }
    func stop() { actions.append("stop") }
    func discardPendingReports() { actions.append("discard") }
}
