import Foundation
import Observation

enum IconState: Equatable { case ready, building, failure, loggedOut, idle }

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

    /// True until the first poll completes. Lets the popover say "Loading…"
    /// instead of "No projects", which reads as an empty account.
    private(set) var isLoadingInitial = true

    // MARK: Legacy / shared surface (still consumed by the current app + tests)
    var teams: [Team] = []
    var user: VercelUser?
    var lastUpdated: Date?
    var scopeName: String

    /// Legacy single-scope view of the merged data, for the not-yet-rewired app.
    var deployments: [Deployment] { sourcedDeployments.map(\.deployment) }
    var projects: [Project] { sourcedProjects.map(\.project) }

    /// Every fetched project across all sources, unfiltered — for the Settings
    /// Projects tab, so follow toggles stay reachable regardless of the active scope.
    var allSourcedProjects: [SourcedProject] { unfilteredProjects }

    /// Derived from `sourceErrors`: none → nil; one → its message; many → summary.
    var errorMessage: String? {
        // Only show the CLI-specific "run vercel login" copy when a CLI account
        // actually exists; otherwise fall through to the sourceErrors-derived message
        // (which tells the user to reconnect the keychain token account instead).
        if isLoggedOut, accountStore.cliAccount != nil {
            return "Not logged in — run `vercel login`"
        }
        switch sourceErrors.count {
        case 0:  return isLoggedOut ? (sourceErrors.values.first ?? "Not signed in") : nil
        case 1:  return sourceErrors.values.first
        default: return "\(sourceErrors.count) accounts couldn't refresh"
        }
    }

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

    /// Last successful fetch per SCOPE (account + team), used to retain a source's
    /// rows across a transient failure (so the menu doesn't blank). Keyed by scope
    /// rather than account because "All" polls several teams of the same account.
    @ObservationIgnored private var lastGood: [ScopeRef: ScopeResult] = [:]

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
            guard let token = accountStore.token(for: account) else { return nil }
            switch account.provider {
            case .vercel:
                return VercelClient(credentials: VercelCredentials(token: token, teamId: teamId))
            case .github:
                return GitHubClient(token: token)
            case .azureDevOps:
                return nil        // unimplemented provider → skipped silently
            }
        }

        // Seed CLI-scope team/user clients + token baseline when a CLI account exists.
        if let cli = accountStore.cliAccount {
            self.currentTeamId = settings.selectedTeamId == "__personal__" ? nil : settings.selectedTeamId
            if let token = accountStore.token(for: cli) {
                self.teamsClient = TeamsClient(token: token)
                self.userClient = UserClient(token: token)
                self.cliBaseToken = token
            }
            // Start from the cached team list so the very first poll already covers
            // every team and rows carry real names — `loadTeams` refreshes it.
            self.teams = settings.cachedTeams
        }

        restoreCachedRows()
    }

    /// Replay the last successful poll so the popover opens with content. Rows
    /// belonging to accounts that are no longer connected are dropped.
    private func restoreCachedRows() {
        let cache = settings.cachedRows
        // A stale snapshot is worse than a brief "Loading…" — deploy states go out
        // of date fast.
        guard cache.savedAt > Date(timeIntervalSinceNow: -Self.rowCacheMaxAge) else { return }

        let byId = Dictionary(uniqueKeysWithValues: accountStore.accounts.map { ($0.id, $0) })
        unfilteredDeployments = cache.deployments.compactMap { $0.restore(accounts: byId) }
        unfilteredProjects = cache.projects.compactMap { $0.restore(accounts: byId) }
        guard !unfilteredDeployments.isEmpty || !unfilteredProjects.isEmpty else { return }

        applyDisplayFilter()
        // Cached rows are shown, so the list is no longer "waiting for first data".
        isLoadingInitial = false
        // Seed the notification baseline from the cache so restored rows don't
        // re-notify as if they were brand new on the first poll.
        previousSnapshots = unfilteredDeployments.map {
            DeploymentSnapshot($0.deployment, key: deploymentKey(for: $0))
        }
    }

    /// Beyond this, a cached snapshot is treated as too stale to show.
    private static let rowCacheMaxAge: TimeInterval = 24 * 60 * 60

    // MARK: - Legacy (single-scope) init — kept for the not-yet-rewired app + tests

    /// Wraps a single Vercel scope (CLI or explicit credentials) into the
    /// aggregator. Used by `DeployBarApp` and the legacy test suites until Task 11
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
                                       reloadCLIToken: { reloadToken() ?? creds.token },
                                       detectGitHubCLI: { false })
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

    /// The scopes actually polled each tick.
    ///
    /// In `.all` we fan out over EVERY Vercel team (plus personal), so the
    /// cross-provider overview is complete rather than showing only whichever
    /// team happens to be active. Any other filter polls just the active scope,
    /// keeping the request count at one per account.
    var availableScopes: [Scope] {
        accountStore.accounts.flatMap { account -> [Scope] in
            guard filter == .all, account.source == .vercelCLI, !teams.isEmpty else {
                let teamId = account.source == .vercelCLI ? currentTeamId : nil
                return [Scope(account: account, teamId: teamId, teamName: nil)]
            }
            let personal = Scope(account: account, teamId: nil, teamName: nil)
            return [personal] + teams.map { team in
                Scope(account: account, teamId: team.id, teamName: team.slug ?? team.name)
            }
        }
    }

    func setFilter(_ filter: ScopeFilter) {
        self.filter = filter
        applyDisplayFilter()
    }

    // MARK: - Filter dropdown helpers (read-only; view-facing)

    /// All connected accounts (mirrors AccountStore.accounts).
    var connectedAccounts: [Account] { accountStore.accounts }

    /// Scopes the user can SELECT for an account in the dropdown. For a Vercel CLI
    /// account this is personal + every team it belongs to (from the loaded `teams`
    /// list); for other accounts, just their single scope. Distinct from
    /// `availableScopes`, which is the one active scope actually polled.
    func scopes(for account: Account) -> [Scope] {
        guard account.source == .vercelCLI, !teams.isEmpty else {
            return availableScopes.filter { $0.account.id == account.id }
        }
        let personal = Scope(account: account, teamId: nil, teamName: nil)
        let teamScopes = teams.map { team in
            Scope(account: account, teamId: team.id, teamName: team.slug ?? team.name)
        }
        return [personal] + teamScopes
    }

    /// Look up an account by UUID.
    func account(_ id: UUID) -> Account? {
        accountStore.accounts.first { $0.id == id }
    }

    /// Newest fetched deployment for a project (same account, matching name) —
    /// enriches rows whose project API carries no latest-deployment info
    /// (GitHub repos get their CI state from the runs already fetched).
    func latestDeployment(for sp: SourcedProject) -> Deployment? {
        unfilteredDeployments.first {
            $0.account.id == sp.account.id && $0.deployment.name == sp.project.name
        }?.deployment
    }

    /// Scope label to show on a row, or nil when the row needs no marker.
    ///
    /// Only meaningful in `.all`, where rows from different accounts/teams sit in
    /// one list; a single-scope view already names its source in the top bar.
    func rowScopeLabel(accountId: UUID, teamId: String?) -> String? {
        guard filter == .all else { return nil }
        guard let acct = account(accountId) else { return nil }
        guard let tid = teamId else { return acct.label }
        // No marker at all until the name is known — a raw "team_xasdf…" id is
        // noise, and the team list may still be loading on a cold first launch.
        return teamDisplayName(tid)
    }

    /// Human-readable name for a scope, e.g. the team name or "personal".
    /// Falls back to the raw id so URL building still has something to work with;
    /// use `rowScopeLabel` for anything user-visible.
    func scopeName(accountId: UUID, teamId: String?) -> String? {
        guard let acct = account(accountId) else { return nil }
        guard let tid = teamId else { return acct.label }
        return teamDisplayName(tid) ?? tid
    }

    /// Like `rowScopeLabel` but independent of the active filter — for the scope
    /// menu, which lists every scope regardless of what's selected.
    func rowScopeLabelIgnoringFilter(accountId: UUID, teamId: String?) -> String? {
        guard let acct = account(accountId) else { return nil }
        guard let tid = teamId else { return acct.label }
        return teamDisplayName(tid)
    }

    /// The team's slug/name, or nil when the team isn't in the (possibly still
    /// loading) list.
    private func teamDisplayName(_ teamId: String) -> String? {
        guard let team = teams.first(where: { $0.id == teamId }) else { return nil }
        return team.slug ?? team.name
    }

    // MARK: - Icon state

    /// Green/red are an "alert" that clears when the user opens the popover; a
    /// fresh success/failure re-raises it. Orange (something running) is a live
    /// status, never acknowledged away.
    private var alertAcknowledged = false

    /// Acknowledge the current green/red alert — called when the popover opens.
    func acknowledge() { alertAcknowledged = true }

    var iconState: IconState {
        if isLoggedOut { return .loggedOut }
        let base = Self.baseState(for: sourcedDeployments.map(\.deployment.state))
        if base == .building { return .building }   // running → orange, always shown
        if alertAcknowledged { return .idle }       // green/red cleared until a new event
        return base                                 // .failure / .ready / .idle
    }

    /// Pure derivation (no acknowledgment): running > failure > ready.
    static func baseState(for states: [DeploymentState]) -> IconState {
        if states.contains(where: { $0 == .building || $0 == .queued }) { return .building }
        if states.contains(.error) { return .failure }
        if states.contains(.ready) { return .ready }
        return .idle
    }

    // MARK: - Build-error copy (provider-aware)

    /// The account a displayed deployment came from, so we can build the correct
    /// provider client for its logs.
    private func sourced(forDeploymentUid uid: String) -> SourcedDeployment? {
        unfilteredDeployments.first { $0.deployment.uid == uid }
            ?? sourcedDeployments.first { $0.deployment.uid == uid }
    }

    /// Fetch the failed deployment's / run's log and copy a context-rich error
    /// report to the clipboard. Works for Vercel deployments and GitHub Actions runs.
    @discardableResult
    func copyBuildError(for deployment: Deployment) async -> Bool {
        if let sourced = sourced(forDeploymentUid: deployment.uid),
           let token = accountStore.token(for: sourced.account) {
            let account = sourced.account
            switch account.provider {
            case .vercel:
                // Use the team the deployment was FETCHED from — in "All" that is
                // not necessarily the currently selected one, and a mismatched
                // teamId makes the build-log request 404.
                let client = VercelClient(credentials: VercelCredentials(token: token, teamId: sourced.teamId))
                guard let events = try? await client.buildEvents(deploymentId: deployment.uid) else { return false }
                Pasteboard.copy(BuildErrorReport.make(for: deployment, events: events))
                return true
            case .github:
                let client = GitHubClient(token: token)
                guard let report = try? await client.failureReport(for: deployment) else { return false }
                Pasteboard.copy(report)
                return true
            case .azureDevOps:
                return false
            }
        }
        return await legacyCopyBuildError(for: deployment)
    }

    /// Legacy single-scope path, retained for the convenience-init test suites
    /// where the client's transport is injected via `legacyClientFactory`.
    private func legacyCopyBuildError(for deployment: Deployment) async -> Bool {
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
        // A failed fetch keeps the cached list rather than blanking scope names.
        guard let fetched = try? await teamsClient.teams() else { return }
        let changed = fetched.map(\.id) != teams.map(\.id)
        self.teams = fetched
        settings.cachedTeams = fetched
        // In "All" the team list defines what gets polled. Re-poll only when the
        // set actually changed — with a warm cache it usually hasn't.
        if filter == .all, changed {
            await poll()
        }
    }

    func loadUser() async {
        guard let userClient else { return }
        if let u = try? await userClient.user() { self.user = u }
    }

    // MARK: - Scope selection (dropdown)

    /// Select the scope shown in the popover: filters deployments AND projects to
    /// that account (+ team), and for the Vercel CLI account also switches the
    /// polled team.
    func select(accountId: UUID, teamId: String?) async {
        filter = .scope(accountId: accountId, teamId: teamId)
        scopeName = scopeName(accountId: accountId, teamId: teamId) ?? "all"
        if account(accountId)?.source == .vercelCLI, teamId != currentTeamId {
            await switchTeam(teamId)
        } else {
            applyDisplayFilter()
        }
    }

    /// Show every connected source at once. Widens `availableScopes` to all Vercel
    /// teams, so this re-polls to pick up the teams a single-scope view never fetched.
    func selectAll() async {
        guard filter != .all else { return }
        filter = .all
        scopeName = "all"
        // Rows already on screen stay visible while the wider fetch lands.
        applyDisplayFilter()
        await poll()
    }

    // MARK: - Legacy team switching (thin compatibility, CLI/first account)

    /// Switch the active team for the CLI account at runtime. `availableScopes`
    /// polls a single scope per account (the CLI account's `currentTeamId`), so
    /// changing the team here changes what gets fetched on the next poll. Persists
    /// the choice, silently re-seeds the notification baseline, and re-polls.
    func switchScope(teamId: String?, scopeName: String) async {
        guard teamId != currentTeamId else { return }
        self.scopeName = scopeName
        await switchTeam(teamId)
    }

    private func switchTeam(_ teamId: String?) async {
        currentTeamId = teamId
        settings.selectedTeamId = teamId ?? "__personal__"
        previousSnapshots = nil               // silent re-seed for the new scope
        sourceErrors = [:]
        // Deliberately NOT clearing the row lists: `applyDisplayFilter` re-derives
        // them from the unfiltered merge, so the popover shows the new scope's
        // known rows immediately instead of flashing empty until the poll lands.
        applyDisplayFilter()
        await poll()
    }

    // MARK: - Lifecycle

    func start() {
        notifier.requestAuthorization()
        // Default view is "All": every connected provider, and every Vercel team,
        // in one list. `scopeName` stays "all" and the filter is left untouched.
        //
        // Teams load asynchronously, so the first poll only covers the persisted
        // team; `loadTeams` re-polls once the full list arrives (see loadTeams()).
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
        /// Vercel team the rows came from; nil for personal / non-Vercel.
        let teamId: String?
        let deployments: [Deployment]
        let projects: [Project]
    }

    func poll() async {
        guard !isPollInFlight else { return }
        isPollInFlight = true
        // Whatever the outcome, the first attempt is over — the popover must stop
        // showing "Loading…" even when there is nothing to show.
        defer { isPollInFlight = false; isLoadingInitial = false }

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
                let ref = ScopeRef(accountId: scope.account.id, teamId: scope.teamId)
                switch result {
                case .success(let (deps, projs)):
                    consecutiveAuthFailures[scope.account.id] = 0
                    freshSuccessCount += 1
                    let res = ScopeResult(account: scope.account, teamId: scope.teamId,
                                          deployments: deps, projects: projs)
                    lastGood[ref] = res
                    merged.append(res)
                case .failure(let error):
                    record(error: error, for: scope.account, into: &errors)
                    // Keep this source's last-known rows so a transient failure
                    // doesn't blank the menu (mirrors the old "stale" behavior).
                    if let prev = lastGood[ref] { merged.append(prev) }
                }
            }
        }

        // Tag + merge across all sources (unfiltered).
        let allDeployments = merged.flatMap { res in
            res.deployments.map {
                SourcedDeployment(deployment: $0, account: res.account, teamId: res.teamId)
            }
        }.sorted { $0.deployment.createdAt > $1.deployment.createdAt }
        let allProjects = merged.flatMap { res in
            res.projects.map {
                SourcedProject(project: $0, account: res.account, teamId: res.teamId)
            }
        }

        // Polling several teams of one account can return the same deployment
        // twice (a project visible in more than one scope). Keep the first —
        // rows are already sorted newest-first — so the list and the notification
        // diff below both see each deployment exactly once.
        self.unfilteredDeployments = allDeployments.deduplicated { (sd: SourcedDeployment) in
            "\(sd.account.id.uuidString)|\(sd.deployment.uid)"
        }
        self.unfilteredProjects = allProjects.deduplicated { (sp: SourcedProject) in
            "\(sp.account.id.uuidString)|\(sp.project.id)"
        }

        // Notification diff runs over the FULL merged set (before display filtering),
        // against the persistent snapshot. Changing the ScopeFilter never re-notifies.
        let snapshots = allDeployments.map {
            DeploymentSnapshot($0.deployment, key: deploymentKey(for: $0))
        }
        let transitions = DeploymentDiffer.transitions(previous: previousSnapshots, current: snapshots)
        notifier.handle(transitions)
        previousSnapshots = snapshots

        // A fresh success/failure re-raises the green/red icon alert the user
        // last acknowledged by opening the popover.
        if transitions.contains(where: { $0.event == .success || $0.event == .failure }) {
            alertAcknowledged = false
        }

        self.sourceErrors = errors
        self.lastUpdated = Date()
        applyDisplayFilter()

        // Persist the merged rows for the next launch. Only when something was
        // actually fetched, so a fully failed tick can't overwrite a good snapshot
        // with an empty one.
        if freshSuccessCount > 0 {
            // Cache the deduplicated merge — the same rows the UI shows.
            settings.cachedRows = RowCache(deployments: unfilteredDeployments,
                                           projects: unfilteredProjects,
                                           savedAt: Date())
        }

        // loggedOut only when there are zero usable sources (no fresh successful
        // fetch this tick AND every account is past the auth-failure threshold).
        let allAuthFailing = scopes.allSatisfy {
            (consecutiveAuthFailures[$0.account.id] ?? 0) >= Self.authFailureThreshold
        }
        isLoggedOut = freshSuccessCount == 0 && allAuthFailing

        // Prune per-account state for accounts that are no longer connected,
        // preventing unbounded growth when accounts are removed.
        let liveIds = Set(accountStore.accounts.map(\.id))
        lastGood = lastGood.filter { liveIds.contains($0.key.accountId) }
        consecutiveAuthFailures = consecutiveAuthFailures.filter { liveIds.contains($0.key) }
    }

    /// Apply the follow filter + active ScopeFilter to the unfiltered merge.
    private func applyDisplayFilter() {
        sourcedDeployments = unfilteredDeployments.filter { sd in
            filter.matches(account: sd.account, teamId: sd.teamId)
                && followed(account: sd.account, projectId: projectId(for: sd), projectName: sd.deployment.name)
        }
        sourcedProjects = unfilteredProjects.filter { sp in
            filter.matches(account: sp.account, teamId: sp.teamId)
                && isFollowed(sp)
        }
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
