import Foundation
import Observation

enum IconState: Equatable { case ready, building, failure, loggedOut }

@MainActor
@Observable
final class DeploymentStore {
    var deployments: [Deployment] = []
    var projects: [Project] = []
    var teams: [Team] = []
    var user: VercelUser?
    var errorMessage: String?
    var lastUpdated: Date?

    var scopeName: String

    @ObservationIgnored private var client: VercelClient
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notifier: NotificationManager
    @ObservationIgnored private var previousSnapshots: [DeploymentSnapshot]?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isPollInFlight = false
    @ObservationIgnored private var isLoggedOut = false
    @ObservationIgnored private var consecutiveAuthFailures = 0
    @ObservationIgnored private var baseToken: String
    @ObservationIgnored private(set) var currentTeamId: String?
    @ObservationIgnored private let makeClient: (VercelCredentials) -> VercelClient
    @ObservationIgnored private var teamsClient: TeamsClient
    @ObservationIgnored private var userClient: UserClient

    /// Re-reads the CLI token from disk. The Vercel CLI rotates the token in
    /// `auth.json` periodically; this lets us pick up a fresh token without a
    /// relaunch. Returns nil when the credentials can't be read (logged out).
    @ObservationIgnored private let reloadToken: () -> String?

    /// Backoff before the in-poll auth retry. Production uses 0.8s; tests pass 0.
    @ObservationIgnored private let authRetryBackoff: Duration

    init(client: VercelClient, settings: SettingsStore, scopeName: String,
         makeClient: @escaping (VercelCredentials) -> VercelClient = { VercelClient(credentials: $0) },
         teamsClient: TeamsClient? = nil,
         userClient: UserClient? = nil,
         reloadToken: @escaping () -> String? = { try? TokenProvider().credentials().token },
         authRetryBackoff: Duration = .milliseconds(800)) {
        self.client = client
        self.settings = settings
        self.notifier = NotificationManager(settings: settings)
        self.baseToken = client.credentials.token
        self.currentTeamId = client.credentials.teamId
        self.scopeName = scopeName
        self.makeClient = makeClient
        self.teamsClient = teamsClient ?? TeamsClient(token: client.credentials.token)
        self.userClient = userClient ?? UserClient(token: client.credentials.token)
        self.reloadToken = reloadToken
        self.authRetryBackoff = authRetryBackoff
    }

    /// Pull a fresh token from disk and, if it changed, rebuild the clients
    /// around it. Returns true when a *new* token was adopted — the caller
    /// should retry the failed request before treating the 401 as a real logout.
    private func refreshTokenIfChanged() -> Bool {
        guard let fresh = reloadToken(), !fresh.isEmpty, fresh != baseToken else { return false }
        baseToken = fresh
        client = makeClient(VercelCredentials(token: fresh, teamId: currentTeamId))
        teamsClient = TeamsClient(token: fresh)
        userClient = UserClient(token: fresh)
        return true
    }

    /// Switch the active team at runtime. `teamId == nil` means personal scope.
    /// Rebuilds the client, resets the notification baseline (silent re-seed),
    /// clears stale data, persists the choice, and re-polls.
    func switchScope(teamId: String?, scopeName: String) async {
        guard teamId != currentTeamId else { return }
        currentTeamId = teamId
        self.scopeName = scopeName
        settings.selectedTeamId = teamId ?? "__personal__"
        // Pick up a freshly-rotated CLI token if there is one, so the new scope's
        // client never starts from a stale token.
        if let fresh = reloadToken(), !fresh.isEmpty { baseToken = fresh }
        client = makeClient(VercelCredentials(token: baseToken, teamId: teamId))
        previousSnapshots = nil          // silent re-seed for the new team
        deployments = []
        projects = []
        errorMessage = nil
        await poll()
    }

    var iconState: IconState {
        if isLoggedOut { return .loggedOut }
        return Self.iconState(for: deployments.map(\.state))
    }

    /// Pure derivation: failure > building > ready.
    static func iconState(for states: [DeploymentState]) -> IconState {
        if states.contains(.error) { return .failure }
        if states.contains(where: { $0 == .building || $0 == .queued }) { return .building }
        return .ready
    }

    /// Fetch the failed deployment's build log and copy a context-rich error
    /// report to the clipboard, ready to paste into an AI. Returns true on
    /// success; on failure leaves the clipboard untouched and returns false.
    @discardableResult
    func copyBuildError(for deployment: Deployment) async -> Bool {
        guard let events = try? await client.buildEvents(deploymentId: deployment.uid) else {
            return false
        }
        let report = BuildErrorReport.make(for: deployment, events: events)
        Pasteboard.copy(report)
        return true
    }

    func loadTeams() async {
        if let fetched = try? await teamsClient.teams() {
            self.teams = fetched
        }
    }

    func loadUser() async {
        if let u = try? await userClient.user() { self.user = u }
    }

    func start() {
        notifier.requestAuthorization()
        Task { await poll() }
        Task { await loadTeams() }
        Task { await loadUser() }
        scheduleTimer()
    }

    /// Re-creatable so the SettingsView can reschedule when the poll interval changes.
    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.pollIntervalSeconds),
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    func poll() async {
        guard !isPollInFlight else { return }
        isPollInFlight = true
        defer { isPollInFlight = false }
        do {
            let (d, p) = try await fetchWithRetry()

            let snapshots = d.map(DeploymentSnapshot.init)
            let transitions = DeploymentDiffer.transitions(previous: previousSnapshots, current: snapshots)
            notifier.handle(transitions)
            previousSnapshots = snapshots

            self.deployments = d.sorted { $0.createdAt > $1.createdAt }
            self.projects = p
            self.errorMessage = nil
            self.lastUpdated = Date()
            self.isLoggedOut = false
            self.consecutiveAuthFailures = 0
        } catch VercelClientError.unauthorized {
            // A single 401/403 is usually transient (rate-limit, token refresh,
            // a request racing a scope switch). Only surface "not logged in"
            // after several consecutive auth failures — a real logout fails
            // every time, a blip recovers on the next tick.
            consecutiveAuthFailures += 1
            if consecutiveAuthFailures >= Self.authFailureThreshold {
                self.errorMessage = "Not logged in — run `vercel login`"
                self.isLoggedOut = true
            }
            // Otherwise keep last-known data and stay quiet; the timer retries soon.
        } catch {
            self.errorMessage = "Couldn't refresh (stale)"
        }
    }

    /// Number of consecutive auth failures before we declare the user logged out.
    private static let authFailureThreshold = 3

    /// Fetch deployments + projects, retrying once on a transient auth failure
    /// before giving the error back to `poll()`. The retry first re-reads the
    /// CLI token from disk — the most common cause of a 401 here is the CLI
    /// having rotated its token out from under our cached copy — and falls back
    /// to a short backoff when the on-disk token is unchanged.
    private func fetchWithRetry() async throws -> ([Deployment], [Project]) {
        do {
            async let deps = client.deployments(limit: 100)
            async let projs = client.projects()
            return try await (deps, projs)
        } catch VercelClientError.unauthorized {
            // Pick up a rotated token immediately; otherwise wait out a momentary blip.
            if !refreshTokenIfChanged() {
                try? await Task.sleep(for: authRetryBackoff)
            }
            async let deps = client.deployments(limit: 100)
            async let projs = client.projects()
            return try await (deps, projs)
        }
    }
}
