import Foundation
import Observation

enum IconState: Equatable { case ready, building, failure, loggedOut }

/// Factory that builds a per-scope provider client for an account+team, pulling
/// the token via the AccountStore. Returns nil for unimplemented providers (skipped).
typealias ClientFactory = @MainActor (Account, _ teamId: String?) -> DeploymentProviderClient?

@MainActor
@Observable
final class DeploymentStore {
    // MARK: New aggregator surface
    private(set) var sourcedDeployments: [SourcedDeployment] = []
    private(set) var sourcedProjects: [SourcedProject] = []
    private(set) var filter: ScopeFilter = .all
    private(set) var sourceErrors: [UUID: String] = [:]

    // MARK: Legacy / shared surface (still consumed by the current app + tests)
    var teams: [Team] = []
    var user: VercelUser?
    var lastUpdated: Date?
    var scopeName: String

    /// Legacy single-scope view of the merged data, for the not-yet-rewired app.
    var deployments: [Deployment] { sourcedDeployments.map(\.deployment) }
    var projects: [Project] { sourcedProjects.map(\.project) }

    /// Derived from `sourceErrors`: none → nil; one → its message; many → summary.
    var errorMessage: String? {
        if isLoggedOut { return "Not logged in — run `vercel login`" }
        switch sourceErrors.count {
        case 0:  return nil
        case 1:  return sourceErrors.values.first
        default: return "\(sourceErrors.count) accounts couldn't refresh"
        }
    }

    /// Number of connected accounts regardless of the active display filter.
    /// Use this for badge gating so the badges don't disappear when a filter is active.
    var connectedSourceCount: Int { accountStore.accounts.count }

    // MARK: Dependencies
    @ObservationIgnored private let accountStore: AccountStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notifier: NotificationManager
    @ObservationIgnored private var makeClient: ClientFactory = { _, _ in nil }

    // MARK: Notification baseline (one list across all sources, keyed by uid)
    @ObservationIgnored private var previousSnapshots: [DeploymentSnapshot]?

    // MARK: Polling machinery
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isPollInFlight = false
    @ObservationIgnored private var isLoggedOut = false

    /// Per-account consecutive auth-failure counters. A real logout fails every
    /// poll; a transient 401 recovers on the next tick.
    @ObservationIgnored private var consecutiveAuthFailures: [UUID: Int] = [:]

    /// Re-reads the CLI token from disk (rotated periodically by the Vercel CLI).
    @ObservationIgnored private let reloadToken: () -> String?
    /// Last CLI token we built clients around — to detect rotation.
    @ObservationIgnored private var cliBaseToken: String?
    /// Backoff before the in-poll auth retry. Production 0.8s; tests pass 0.
    @ObservationIgnored private let authRetryBackoff: Duration

    // MARK: Legacy single-scope team switching (CLI/first account only)
    @ObservationIgnored private(set) var currentTeamId: String?
    @ObservationIgnored private var teamsClient: TeamsClient?
    @ObservationIgnored private var userClient: UserClient?

    // Legacy single-scope context (nil in pure aggregator mode).
    @ObservationIgnored private var legacyAccount: Account?
    @ObservationIgnored private var legacyClientFactory: ((VercelCredentials) -> VercelClient)?
    @ObservationIgnored private var legacyCredentials: VercelCredentials?

    // Unfiltered merge, kept so `setFilter` can re-derive the display slice
    // without re-polling.
    @ObservationIgnored private var unfilteredDeployments: [SourcedDeployment] = []
    @ObservationIgnored private var unfilteredProjects: [SourcedProject] = []

    /// Last successful fetch per account, used to retain a source's rows across a
    /// transient failure (so the menu doesn't blank).
    @ObservationIgnored private var lastGood: [UUID: ScopeResult] = [:]

    /// Number of consecutive auth failures before we declare an account logged out.
    private static let authFailureThreshold = 3

    // MARK: - Designated (aggregator) init

    init(accountStore: AccountStore,
         settings: SettingsStore,
         makeClient: ClientFactory? = nil,
         reloadToken: @escaping () -> String? = { try? TokenProvider().credentials().token },
         authRetryBackoff: Duration = .milliseconds(800)) {
        self.accountStore = accountStore
        self.settings = settings
        self.notifier = NotificationManager(settings: settings)
        self.reloadToken = reloadToken
        self.authRetryBackoff = authRetryBackoff
        self.scopeName = "all"

        // Default factory: build a real VercelClient for .vercel accounts using
        // the token from this store's AccountStore; nil for other providers.
        self.makeClient = makeClient ?? { [accountStore] account, teamId in
            guard account.provider == .vercel,
                  let token = accountStore.token(for: account) else { return nil }
            return VercelClient(credentials: VercelCredentials(token: token, teamId: teamId))
        }

        // Seed CLI-scope team/user clients + token baseline when a CLI account exists.
        if let cli = accountStore.cliAccount {
            self.currentTeamId = settings.selectedTeamId == "__personal__" ? nil : settings.selectedTeamId
            if let token = accountStore.token(for: cli) {
                self.teamsClient = TeamsClient(token: token)
                self.userClient = UserClient(token: token)
                self.cliBaseToken = token
            }
        }
    }

    // MARK: - Legacy (single-scope) init — kept for the not-yet-rewired app + tests

    /// Wraps a single Vercel scope (CLI or explicit credentials) into the
    /// aggregator. Used by `VercelBarApp` and the legacy test suites until Task 11
    /// rewires the app onto the multi-account path.
    convenience init(client: VercelClient,
                     settings: SettingsStore,
                     scopeName: String,
                     makeClient: @escaping (VercelCredentials) -> VercelClient = { VercelClient(credentials: $0) },
                     teamsClient: TeamsClient? = nil,
                     userClient: UserClient? = nil,
                     reloadToken: @escaping () -> String? = { try? TokenProvider().credentials().token },
                     authRetryBackoff: Duration = .milliseconds(800)) {
        // A single in-memory CLI account stands in for the legacy single scope.
        let creds = client.credentials
        let legacyStore = AccountStore(defaults: UserDefaults(suiteName: "legacy-\(UUID().uuidString)")!,
                                       credentials: InMemoryCredentialStore(),
                                       detectCLI: { true },
                                       reloadCLIToken: { reloadToken() ?? creds.token })
        let legacyAccount = legacyStore.cliAccount!

        self.init(accountStore: legacyStore,
                  settings: settings,
                  makeClient: { account, teamId in
                      guard account.id == legacyAccount.id else { return nil }
                      let token = reloadToken() ?? creds.token
                      // Reuse the original client (and its injected transport) while
                      // the token is unchanged; rebuild via `makeClient` only after a
                      // rotation, where the test transport is re-captured by `makeClient`.
                      if token == creds.token && teamId == creds.teamId { return client }
                      return makeClient(VercelCredentials(token: token, teamId: teamId))
                  },
                  reloadToken: reloadToken,
                  authRetryBackoff: authRetryBackoff)
        self.scopeName = scopeName
        self.currentTeamId = creds.teamId
        self.legacyAccount = legacyAccount
        self.legacyClientFactory = makeClient
        self.legacyCredentials = creds
        self.teamsClient = teamsClient ?? TeamsClient(token: creds.token)
        self.userClient = userClient ?? UserClient(token: creds.token)
        self.cliBaseToken = creds.token
    }

    // MARK: - Scopes

    /// One `Scope` per connected account: its default scope (CLI → persisted/CLI
    /// team or personal; keychain → personal). Multi-team expansion is out of scope.
    var availableScopes: [Scope] {
        accountStore.accounts.map { account in
            let teamId = account.source == .vercelCLI ? currentTeamId : nil
            return Scope(account: account, teamId: teamId, teamName: nil)
        }
    }

    func setFilter(_ filter: ScopeFilter) {
        self.filter = filter
        applyDisplayFilter()
    }

    // MARK: - Filter dropdown helpers (read-only; view-facing)

    /// All connected accounts (mirrors AccountStore.accounts).
    var connectedAccounts: [Account] { accountStore.accounts }

    /// The scopes belonging to a given account (from `availableScopes`).
    func scopes(for account: Account) -> [Scope] {
        availableScopes.filter { $0.account.id == account.id }
    }

    /// Look up an account by UUID.
    func account(_ id: UUID) -> Account? {
        accountStore.accounts.first { $0.id == id }
    }

    /// Human-readable name for a scope, e.g. the team name or "personal".
    func scopeName(accountId: UUID, teamId: String?) -> String? {
        guard let acct = account(accountId) else { return nil }
        if let tid = teamId {
            if let team = teams.first(where: { $0.id == tid }) {
                return team.slug ?? team.name ?? tid
            }
            return tid
        }
        return acct.label
    }

    // MARK: - Icon state

    var iconState: IconState {
        if isLoggedOut { return .loggedOut }
        return Self.iconState(for: sourcedDeployments.map(\.deployment.state))
    }

    /// Pure derivation: failure > building > ready.
    static func iconState(for states: [DeploymentState]) -> IconState {
        if states.contains(.error) { return .failure }
        if states.contains(where: { $0 == .building || $0 == .queued }) { return .building }
        return .ready
    }

    // MARK: - Build-error copy (legacy single-scope helper)

    /// Fetch the failed deployment's build log and copy a context-rich error
    /// report to the clipboard. Only works for the legacy Vercel scope.
    @discardableResult
    func copyBuildError(for deployment: Deployment) async -> Bool {
        guard let creds = legacyCredentials,
              let factory = legacyClientFactory else { return false }
        let client = factory(VercelCredentials(token: cliBaseToken ?? creds.token, teamId: currentTeamId))
        guard let events = try? await client.buildEvents(deploymentId: deployment.uid) else {
            return false
        }
        Pasteboard.copy(BuildErrorReport.make(for: deployment, events: events))
        return true
    }

    // MARK: - Teams / user (account-level; CLI/first account)

    func loadTeams() async {
        guard let teamsClient else { return }
        if let fetched = try? await teamsClient.teams() { self.teams = fetched }
    }

    func loadUser() async {
        guard let userClient else { return }
        if let u = try? await userClient.user() { self.user = u }
    }

    // MARK: - Legacy team switching (thin compatibility, CLI/first account)

    /// Switch the active team for the legacy CLI scope at runtime. Retained so the
    /// current (not-yet-rewired) app keeps its team picker working; Task 11 will
    /// replace this with `setFilter`. No-op in pure multi-account mode.
    func switchScope(teamId: String?, scopeName: String) async {
        guard legacyAccount != nil else { return }
        guard teamId != currentTeamId else { return }
        currentTeamId = teamId
        self.scopeName = scopeName
        settings.selectedTeamId = teamId ?? "__personal__"
        previousSnapshots = nil               // silent re-seed for the new scope
        sourcedDeployments = []
        sourcedProjects = []
        sourceErrors = [:]
        await poll()
    }

    // MARK: - Lifecycle

    func start() {
        notifier.requestAuthorization()
        Task { await poll() }
        Task { await loadTeams() }
        Task { await loadUser() }
        scheduleTimer()
    }

    /// Re-creatable so SettingsView can reschedule when the poll interval changes.
    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.pollIntervalSeconds),
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    // MARK: - Polling (fan out across scopes)

    private struct ScopeResult {
        let account: Account
        let deployments: [Deployment]
        let projects: [Project]
    }

    func poll() async {
        guard !isPollInFlight else { return }
        isPollInFlight = true
        defer { isPollInFlight = false }

        let scopes = availableScopes
        guard !scopes.isEmpty else {
            isLoggedOut = true        // no connected accounts at all
            return
        }

        var merged: [ScopeResult] = []
        var errors: [UUID: String] = [:]
        var freshSuccessCount = 0

        // Fan out one fetch per scope. withTaskGroup keeps per-source isolation:
        // one source throwing never cancels the others.
        await withTaskGroup(of: (Scope, Result<([Deployment], [Project]), Error>).self) { group in
            for scope in scopes {
                group.addTask { @MainActor in
                    do { return (scope, .success(try await self.fetch(for: scope))) }
                    catch { return (scope, .failure(error)) }
                }
            }
            for await (scope, result) in group {
                switch result {
                case .success(let (deps, projs)):
                    consecutiveAuthFailures[scope.account.id] = 0
                    freshSuccessCount += 1
                    let res = ScopeResult(account: scope.account, deployments: deps, projects: projs)
                    lastGood[scope.account.id] = res
                    merged.append(res)
                case .failure(let error):
                    record(error: error, for: scope.account, into: &errors)
                    // Keep this source's last-known rows so a transient failure
                    // doesn't blank the menu (mirrors the old "stale" behavior).
                    if let prev = lastGood[scope.account.id] { merged.append(prev) }
                }
            }
        }

        // Tag + merge across all sources (unfiltered).
        let allDeployments = merged.flatMap { res in
            res.deployments.map { SourcedDeployment(deployment: $0, account: res.account) }
        }.sorted { $0.deployment.createdAt > $1.deployment.createdAt }
        let allProjects = merged.flatMap { res in
            res.projects.map { SourcedProject(project: $0, account: res.account) }
        }

        self.unfilteredDeployments = allDeployments
        self.unfilteredProjects = allProjects

        // Notification diff runs over the FULL merged set (before display filtering),
        // against the persistent snapshot. Changing the ScopeFilter never re-notifies.
        let snapshots = allDeployments.map {
            DeploymentSnapshot($0.deployment, key: deploymentKey(for: $0))
        }
        let transitions = DeploymentDiffer.transitions(previous: previousSnapshots, current: snapshots)
        notifier.handle(transitions)
        previousSnapshots = snapshots

        self.sourceErrors = errors
        self.lastUpdated = Date()
        applyDisplayFilter()

        // loggedOut only when there are zero usable sources (no fresh successful
        // fetch this tick AND every account is past the auth-failure threshold).
        let allAuthFailing = scopes.allSatisfy {
            (consecutiveAuthFailures[$0.account.id] ?? 0) >= Self.authFailureThreshold
        }
        isLoggedOut = freshSuccessCount == 0 && allAuthFailing
    }

    /// Apply the follow filter + active ScopeFilter to the unfiltered merge.
    private func applyDisplayFilter() {
        sourcedDeployments = unfilteredDeployments.filter { sd in
            filter.matches(account: sd.account, teamId: scopeTeamId(for: sd.account))
                && followed(account: sd.account, projectId: projectId(for: sd), projectName: sd.deployment.name)
        }
        sourcedProjects = unfilteredProjects.filter { sp in
            filter.matches(account: sp.account, teamId: scopeTeamId(for: sp.account))
                && isFollowed(sp)
        }
    }

    private func scopeTeamId(for account: Account) -> String? {
        account.source == .vercelCLI ? currentTeamId : nil
    }

    /// Resolve a deployment to its project id when the project is known, so the
    /// id-based follow key matches; falls back to the project name.
    private func projectId(for sd: SourcedDeployment) -> String {
        unfilteredProjects.first {
            $0.account.id == sd.account.id && $0.project.name == sd.deployment.name
        }?.project.id ?? sd.deployment.name
    }

    // MARK: - Follow resolution (with CLI-only legacy name fallback)

    /// Whether a `SourcedProject` is followed, honoring the CLI-account legacy
    /// name-keyed mute migration.
    func isFollowed(_ sp: SourcedProject) -> Bool {
        followed(account: sp.account, projectId: sp.project.id, projectName: sp.project.name)
    }

    /// Sets follow state for a project, keeping the legacy CLI name-key in sync
    /// so a re-enable actually un-hides a previously name-muted CLI project.
    func setFollowed(_ sp: SourcedProject, _ followed: Bool) {
        let idKey = ProjectKey(provider: sp.account.provider, accountId: sp.account.id, projectId: sp.project.id)
        settings.setFollowed(idKey, followed)
        if sp.account.source == .vercelCLI {
            let nameKey = ProjectKey(provider: .vercel, accountId: sp.account.id, projectId: sp.project.name)
            settings.setFollowed(nameKey, followed)
        }
    }

    /// Core follow check. Explicit id-based key is the primary; for the CLI account
    /// ONLY, also honor a legacy name-based key (Task 8 stored old mutes by name).
    /// If either key says unfollowed, treat as unfollowed.
    private func followed(account: Account, projectId: String, projectName: String) -> Bool {
        let idKey = ProjectKey(provider: account.provider, accountId: account.id, projectId: projectId)
        let idFollowed = settings.isFollowed(idKey)
        guard account.source == .vercelCLI else { return idFollowed }
        let nameKey = ProjectKey(provider: .vercel, accountId: account.id, projectId: projectName)
        return idFollowed && settings.isFollowed(nameKey)
    }

    /// The notification key for a deployment: id-based when the project is known;
    /// otherwise the name (matches the legacy/CLI key). Reuses `projectId(for:)`
    /// so there is a single project lookup.
    private func deploymentKey(for sd: SourcedDeployment) -> ProjectKey {
        ProjectKey(provider: sd.account.provider, accountId: sd.account.id, projectId: projectId(for: sd))
    }

    // MARK: - Per-scope fetch + auth handling

    private func fetch(for scope: Scope) async throws -> ([Deployment], [Project]) {
        guard let client = makeClient(scope.account, scope.teamId) else {
            return ([], [])          // unimplemented provider → skip silently
        }
        do {
            async let deps = client.deployments(limit: 100)
            async let projs = client.projects()
            return try await (deps, projs)
        } catch VercelClientError.unauthorized {
            // CLI scope: a 401 is most often a rotated token — reload + retry.
            // Other accounts: short backoff then a single retry.
            let retryClient: DeploymentProviderClient
            if scope.account.source == .vercelCLI, refreshCLITokenIfChanged() {
                retryClient = makeClient(scope.account, scope.teamId) ?? client
            } else {
                try? await Task.sleep(for: authRetryBackoff)
                retryClient = client
            }
            async let deps = retryClient.deployments(limit: 100)
            async let projs = retryClient.projects()
            return try await (deps, projs)
        }
    }

    /// Pull a fresh CLI token from disk; if it changed, rebuild the team/user
    /// clients around it and report true so the caller retries the failed fetch.
    private func refreshCLITokenIfChanged() -> Bool {
        guard let fresh = reloadToken(), !fresh.isEmpty, fresh != cliBaseToken else { return false }
        cliBaseToken = fresh
        teamsClient = TeamsClient(token: fresh)
        userClient = UserClient(token: fresh)
        return true
    }

    private func record(error: Error, for account: Account, into errors: inout [UUID: String]) {
        if case VercelClientError.unauthorized = error {
            consecutiveAuthFailures[account.id, default: 0] += 1
            if (consecutiveAuthFailures[account.id] ?? 0) >= Self.authFailureThreshold {
                errors[account.id] = "Not logged in — reconnect \(account.label)"
            }
            // Below threshold: stay quiet, keep last-known rows; the timer retries.
        } else {
            errors[account.id] = "Couldn't refresh \(account.label) (stale)"
        }
    }
}
