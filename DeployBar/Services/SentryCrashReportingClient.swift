import Foundation
import Sentry

@MainActor
final class SentryCrashReportingClient: CrashReportingClient {
    private let cache: CrashReportCache
    private var session: URLSession?
    private var consent: CrashReportConsent?
    private var cacheIsUsable = true

    init(cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("io.eightlines.deploybar.DeployBar/CrashReports", isDirectory: true)) {
        self.cache = CrashReportCache(directory: cacheDirectory)
    }

    func start() {
        guard session == nil, cacheIsUsable else { return }
        guard let grant = try? cache.prepare() else { return }
        let session = URLSession(configuration: .ephemeral)
        let consent = CrashReportConsent(notBefore: grant.startedAt)
        self.session = session
        self.consent = consent
        let options = Self.options(cacheDirectory: cache.directory(for: grant), session: session, consent: consent)
        SentrySDK.start(options: options)
    }

    func stop() {
        guard let session else { return }
        consent?.revoke()
        // close() flushes the SDK. Invalidate its dedicated transport first so
        // that flush cannot send queued envelopes after consent is revoked.
        session.invalidateAndCancel()
        SentrySDK.close()
        self.session = nil
        consent = nil
    }

    func discardPendingReports() {
        do {
            try cache.discard()
            cacheIsUsable = true
        } catch {
            // Fail closed: do not restart with data we could not discard.
            cacheIsUsable = false
        }
    }

    nonisolated static func options(cacheDirectory: URL, session: URLSession,
                                    consent: CrashReportConsent) -> Options {
        let options = Options()
        options.dsn = "https://b7f1b1e1e8f4c7fef335fb86f6bf8a3f@o4512118384623616.ingest.de.sentry.io/4512118454812752"
        options.debug = false
        options.sendDefaultPii = false
        options.cacheDirectoryPath = cacheDirectory.path
        options.urlSession = session
        options.shutdownTimeInterval = 0
        options.enableUncaughtNSExceptionReporting = true
        options.enableMemoryIntrospection = false
        options.enableAutoSessionTracking = false
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.maxBreadcrumbs = 0
        options.maxAttachmentSize = 0
        options.enableAutoPerformanceTracing = false
        options.enableNetworkTracking = false
        options.enableCaptureFailedRequests = false
        options.tracePropagationTargets = []
        options.sendClientReports = false
        options.enableLogs = false
        options.enableMetricKit = false
        // Zero disables the deprecated app-hang integration without opting in
        // to MetricKit diagnostics, which are outside crash-report consent.
        options.appHangTimeoutInterval = 0
        #if DEBUG
        options.environment = "development"
        #else
        options.environment = "production"
        #endif
        options.beforeSend = { event in
            guard consent.allows(event.timestamp) else { return nil }
            return sanitize(event)
        }
        options.beforeBreadcrumb = { _ in nil }
        return options
    }

    /// Construct a report from an allowlist. Free-form error messages can
    /// contain provider responses, URLs or tokens even with default PII off.
    nonisolated static func sanitize(_ event: Event) -> Event {
        let clean = Event(level: event.level)
        clean.eventId = event.eventId
        clean.timestamp = event.timestamp
        clean.platform = event.platform
        clean.releaseName = event.releaseName
        clean.dist = event.dist
        clean.environment = event.environment
        clean.sdk = event.sdk
        if event.message != nil {
            clean.message = SentryMessage(formatted: "DeployBar crash report")
        }
        let fields: [String: Set<String>] = [
            "os": ["name", "version", "build"],
            "app": ["app_version", "app_build", "app_identifier"],
            "device": ["family", "model", "arch", "memory_size", "processor_count"],
            "runtime": ["name", "version"]
        ]
        clean.context = [:]
        for (name, allowed) in fields {
            if let context = event.context?[name] {
                clean.context?[name] = context.filter { allowed.contains($0.key) }
            }
        }
        clean.exceptions = event.exceptions
        for exception in clean.exceptions ?? [] {
            exception.value = nil
            exception.module = nil
            exception.mechanism?.desc = nil
            exception.mechanism?.data = nil
            exception.mechanism?.helpLink = nil
            sanitizeStack(exception.stacktrace)
        }
        clean.threads = event.threads
        for thread in clean.threads ?? [] {
            thread.name = nil
            sanitizeStack(thread.stacktrace)
        }
        clean.stacktrace = event.stacktrace
        sanitizeStack(clean.stacktrace)
        clean.debugMeta = event.debugMeta
        for image in clean.debugMeta ?? [] {
            image.codeFile = image.codeFile.map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        return clean
    }

    nonisolated private static func sanitizeStack(_ stack: SentryStacktrace?) {
        for frame in stack?.frames ?? [] {
            frame.fileName = nil
            frame.package = frame.package.map { URL(fileURLWithPath: $0).lastPathComponent }
            frame.module = frame.module.map { URL(fileURLWithPath: $0).lastPathComponent }
            frame.vars = nil
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
        }
    }
}

/// Sentry invokes beforeSend on background threads. Each SDK start gets a new
/// gate so callbacks from a revoked session can never use a later grant.
final class CrashReportConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = true
    private let notBefore: Date

    init(notBefore: Date = Date()) { self.notBefore = notBefore }

    var isGranted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    func allows(_ timestamp: Date?) -> Bool {
        guard let timestamp else { return false }
        return isGranted && timestamp >= notBefore
    }

    func revoke() {
        lock.lock()
        defer { lock.unlock() }
        granted = false
    }
}
