import AppKit
import Foundation
import Observation
import os

/// What the menu bar glyph shows. There is deliberately no "ready" case: a
/// successful deploy and a quiet bar draw the same upright rocket, so the
/// distinction was invisible in the one place this type is used.
enum IconState: Equatable { case building, failure, loggedOut, idle }

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
    /// One message per *failing scope* (account+team), not per account: in "All"
    /// mode a single Vercel account fans out into personal + one scope per team,
    /// and those fail independently. Keying by account alone let a healthy team
    /// hide a broken one, and concurrent failures of the same account overwrote
    /// each other in completion order.
    private(set) var scopeErrors: [ScopeRef: String] = [:]

    /// Account-keyed view of `scopeErrors`, for callers that think in accounts.
    /// When several scopes of one account fail, the messages are joined in a
    /// stable order so repeated polls don't reshuffle the text.
    var sourceErrors: [UUID: String] {
        Dictionary(grouping: scopeErrors, by: { $0.key.accountId })
            .mapValues { $0.map(\.value).sorted().joined(separator: "\n") }
    }

    /// True while a poll is in flight. Observed (unlike `isPollInFlight`, which
    /// is a plain re-entrancy guard) so the health dot can show that a manual
    /// refresh is actually doing something — a click with no feedback reads as
    /// a dead control.
    private(set) var isRefreshing = false

    /// True until the first poll completes. Lets the popover say "Loading…"
    /// instead of "No projects", which reads as an empty account.
    private(set) var isLoadingInitial = true

    // MARK: Legacy / shared surface (still consumed by the current app + tests)

    /// Organizations per account: Vercel teams and GitHub orgs alike. Replaces
    /// the single global team list, which could only ever describe one account.
    private(set) var orgsByAccount: [UUID: [Team]] = [:]

    /// The CLI account's organizations, under the old name. Kept settable so the
    /// existing tests that seed a team list keep working; both paths funnel
    /// through `orgsByAccount`, so there is still one source of truth.
    var teams: [Team] {
        get {
            guard let cli = accountStore.cliAccount else { return [] }
            return orgsByAccount[cli.id] ?? []
        }
        set {
            guard let cli = accountStore.cliAccount else { return }
            setOrganizations(newValue, for: cli.id)
        }
    }

    /// Organizations known for a given account, or empty until fetched/cached.
    func organizations(for account: Account) -> [Team] {
        orgsByAccount[account.id] ?? []
    }

    /// Records a freshly fetched organization list and caches it, so the next
    /// launch can label and poll every scope before the network answers.
    func setOrganizations(_ orgs: [Team], for accountId: UUID) {
        orgsByAccount[accountId] = orgs
        var cache = settings.cachedOrgs
        cache[accountId] = orgs
        settings.cachedOrgs = cache
    }

    var user: VercelUser?
    var lastUpdated: Date?
    var scopeName: String

    /// Legacy single-scope view of the merged data, for the not-yet-rewired app.
    var deployments: [Deployment] { sourcedDeployments.map(\.deployment) }
    var projects: [Project] { sourcedProjects.map(\.project) }

    /// Every fetched project across all sources, unfiltered — for the Settings
    /// Projects tab, so follow toggles stay reachable regardless of the active scope.
    var allSourcedProjects: [SourcedProject] { unfilteredProjects }

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
    /// The poll currently running (or the last one chained onto it). Lets
    /// `poll()` coalesce racing callers instead of dropping their request.
    @ObservationIgnored private var currentPoll: Task<Void, Never>?
    /// Wake observer, so a sleeping Mac refreshes the moment it comes back.
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var isLoggedOut = false

    /// Per-*scope* consecutive auth-failure counters. A real logout fails every
    /// poll; a transient 401 recovers on the next tick.
    ///
    /// Keyed by scope rather than account for the same reason as `scopeErrors`:
    /// one team's success used to zero the counter for every other team of the
    /// same account, so a genuinely revoked team scope never reached the
    /// threshold and never reported itself.
    @ObservationIgnored private var consecutiveAuthFailures: [ScopeRef: Int] = [:]

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
                return VercelClient(credentials: VercelCredentials(token: token, teamId: teamId),
                                    fetch: accountStore.vercelFetch(for: account))
            case .github:
                return GitHubClient(token: token, org: teamId)
            case .azureDevOps:
                return nil        // unimplemented provider → skipped silently
            }
        }

        // Seed CLI-scope team/user clients + token baseline when a CLI account exists.
        if let cli = accountStore.cliAccount {
            self.currentTeamId = settings.selectedTeamId == "__personal__" ? nil : settings.selectedTeamId
            if let token = accountStore.token(for: cli) {
                self.teamsClient = TeamsClient(token: token, fetch: accountStore.vercelFetch(for: cli))
                self.userClient = UserClient(token: token, fetch: accountStore.vercelFetch(for: cli))
                self.cliBaseToken = token
            }
            // Start from the cached org/team lists so the very first poll already
            // covers every scope and rows carry real names — `loadTeams` and
            // `loadGitHubOrganizations` refresh them.
            settings.migrateCachedTeams(cliAccountId: cli.id)
        }
        self.orgsByAccount = settings.cachedOrgs

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
        // Sorted on the way in, not trusted from disk: a snapshot written before
        // `displayOrder` existed would otherwise paint in its old arbitrary order
        // and then visibly jump when the first poll lands.
        unfilteredProjects = cache.projects
            .compactMap { $0.restore(accounts: byId) }
            .sorted(by: SourcedProject.displayOrder)
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

    /// The scopes actually polled each tick: every enabled scope of every
    /// account — the account itself plus each of its organizations.
    ///
    /// No longer conditional on the provider. A GitHub organization and a
    /// Vercel team are the same kind of source, and both fan out here so the
    /// cross-provider overview is complete rather than showing only whichever
    /// one happens to be active.
    var availableScopes: [Scope] {
        accountStore.accounts.flatMap { account -> [Scope] in
            allScopes(for: account).filter { scope in
                settings.isScopeEnabled(
                    ScopeRef(accountId: account.id, teamId: scope.teamId).id)
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

    // MARK: - Health (view-facing)

    /// Every current problem, one line per failing source, ordered by account so
    /// the list doesn't reshuffle between polls (`sourceErrors` is a dictionary).
    ///
    /// Replaces the bottom status bar: the same information now hangs off the
    /// health dot beside the scope picker.
    var healthIssues: [String] {
        // A full logout isn't attributable to one source — `sourceErrors` may
        // even be empty — so it is reported on its own.
        if isLoggedOut {
            if accountStore.cliAccount != nil {
                return [String(localized: "Not logged in — run `vercel login`",
                               comment: "Health issue: the Vercel CLI has no session")]
            }
            if let first = sourceErrors.values.sorted().first { return [first] }
            return [String(localized: "Not signed in",
                           comment: "Health issue: no account is connected")]
        }
        // Ordered by the account list, then by id for sources with no account,
        // so repeated polls produce a stable list.
        let ordered = accountStore.accounts.compactMap { sourceErrors[$0.id] }
        let known = Set(accountStore.accounts.map(\.id))
        let orphans = sourceErrors.filter { !known.contains($0.key) }.values.sorted()
        return ordered + orphans
    }

    /// Scopes the user can SELECT for an account, including disabled ones —
    /// Settings has to list an organization in order to switch it back on.
    /// Distinct from `availableScopes`, which excludes disabled scopes.
    func scopes(for account: Account) -> [Scope] {
        allScopes(for: account)
    }

    /// Every scope of an account: the account itself, plus one per organization
    /// (Vercel team or GitHub org alike). Includes disabled scopes; callers that
    /// only want polled scopes filter through `settings.isScopeEnabled`.
    private func allScopes(for account: Account) -> [Scope] {
        let orgs = organizations(for: account)
        // A Vercel CLI account with no fetched teams still polls whichever team
        // the CLI itself is pointed at.
        guard !orgs.isEmpty else {
            let teamId = account.source == .vercelCLI ? currentTeamId : nil
            return [Scope(account: account, teamId: teamId, teamName: nil)]
        }
        let accountScope = Scope(account: account, teamId: nil, teamName: nil)
        return [accountScope] + orgs.map { org in
            Scope(account: account, teamId: org.id, teamName: org.slug ?? org.name)
        }
    }

    /// Look up an account by UUID.
    func account(_ id: UUID) -> Account? {
        accountStore.accounts.first { $0.id == id }
    }

    /// Account-level scope ids, sorted — the input to default colour assignment.
    ///
    /// Organizations are deliberately excluded. They inherit their account's
    /// colour, so including them would both waste palette slots and let
    /// discovering a new organization reshuffle every existing account's colour.
    var allScopeIds: [String] {
        connectedAccounts.map { ScopeRef(accountId: $0.id, teamId: nil).id }
    }

    /// Palette slot for a scope's marker, resolved in order: an explicit
    /// override, else the account's colour for an organization scope, else the
    /// slot derived from the account's position.
    ///
    /// Inheritance is what keeps a 30-organization account readable: one colour
    /// per account until an organization is deliberately given its own.
    func scopeColorIndex(accountId: UUID, teamId: String?) -> Int {
        let id = ScopeRef(accountId: accountId, teamId: teamId).id
        if let override = settings.scopeColorOverrides[id] { return override }
        if teamId != nil {
            let accountId_ = ScopeRef(accountId: accountId, teamId: nil).id
            if let inherited = settings.scopeColorOverrides[accountId_] { return inherited }
            return ScopeColorIndex.index(for: accountId_, among: allScopeIds)
        }
        return ScopeColorIndex.index(for: id, among: allScopeIds)
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
        // noise, and the org/team list may still be loading on a cold first launch.
        return teamDisplayName(tid, accountId: accountId)
    }

    /// Human-readable name for a scope, e.g. the team name or "personal".
    /// Falls back to the raw id so URL building still has something to work with;
    /// use `rowScopeLabel` for anything user-visible.
    func scopeName(accountId: UUID, teamId: String?) -> String? {
        guard let acct = account(accountId) else { return nil }
        guard let tid = teamId else { return acct.label }
        return teamDisplayName(tid, accountId: accountId) ?? tid
    }

    /// The organization a project belongs to, for the `owner/project` title.
    ///
    /// Distinct from `rowScopeLabelIgnoringFilter`: for the *personal* scope that
    /// returns the account's label ("Vercel CLI"), which is this app's name for
    /// the credential, not an org. Vercel itself scopes personal projects under
    /// the user's own username, so use that — giving "konrad-8lines/social"
    /// rather than "Vercel CLI/social".
    func projectOwnerLabel(accountId: UUID, teamId: String?) -> String? {
        if let teamId { return teamDisplayName(teamId, accountId: accountId) }
        guard let acct = account(accountId) else { return nil }
        // GitHub repos already carry their owner in the project name, so only
        // Vercel's personal scope needs the username substituted in.
        guard acct.provider == .vercel else { return nil }
        return user?.username ?? nil
    }

    /// Like `rowScopeLabel` but independent of the active filter — for the scope
    /// menu, which lists every scope regardless of what's selected.
    func rowScopeLabelIgnoringFilter(accountId: UUID, teamId: String?) -> String? {
        guard let acct = account(accountId) else { return nil }
        guard let tid = teamId else { return acct.label }
        return teamDisplayName(tid, accountId: accountId)
    }

    /// The organization's slug/name for the given account, or nil when the
    /// org isn't in the (possibly still loading) list.
    private func teamDisplayName(_ teamId: String, accountId: UUID) -> String? {
        guard let team = (orgsByAccount[accountId] ?? []).first(where: { $0.id == teamId })
        else { return nil }
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
        if alertAcknowledged { return .idle }       // red cleared until a new event
        return base                                 // .failure / .idle
    }

    /// Pure derivation (no acknowledgment): running > failure > idle.
    static func baseState(for states: [DeploymentState]) -> IconState {
        if states.contains(where: { $0 == .building || $0 == .queued }) { return .building }
        if states.contains(.error) { return .failure }
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
                let client = VercelClient(credentials: VercelCredentials(token: token, teamId: sourced.teamId),
                                          fetch: accountStore.vercelFetch(for: account))
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
        guard let teamsClient, let cli = accountStore.cliAccount else { return }
        // A failed fetch keeps the cached list rather than blanking scope names.
        guard let fetched = try? await teamsClient.teams() else { return }
        let changed = fetched.map(\.id) != teams.map(\.id)
        setOrganizations(fetched, for: cli.id)
        // In "All" the team list defines what gets polled. Re-poll only when the
        // set actually changed — with a warm cache it usually hasn't.
        if filter == .all, changed {
            await poll()
        }
    }

    /// Loads each GitHub account's organizations so they become scopes. A
    /// failure is non-fatal: the account keeps its single account-level scope,
    /// exactly as before this existed.
    func loadGitHubOrganizations() async {
        for account in accountStore.accounts where account.provider == .github {
            guard let token = accountStore.token(for: account) else { continue }
            do {
                let orgs = try await GitHubOrgsClient(token: token).organizations()
                let changed = orgs.map(\.id) != organizations(for: account).map(\.id)
                setOrganizations(orgs, for: account.id)
                // Mirrors `loadTeams`: a newly discovered organization must not
                // wait for the next timer tick before it is polled.
                if filter == .all, changed {
                    await poll()
                }
            } catch {
                os_log("github org fetch failed for %{public}@: %{public}@",
                       account.label, error.localizedDescription)
            }
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
        scopeErrors = [:]
        // Deliberately NOT clearing the row lists: `applyDisplayFilter` re-derives
        // them from the unfiltered merge, so the popover shows the new scope's
        // known rows immediately instead of flashing empty until the poll lands.
        applyDisplayFilter()
        await poll()
    }

    // MARK: - Lifecycle

    /// Idempotent: the app starts the store at launch, and the popover's
    /// `.task` also calls it the first time it appears. Only the first call
    /// registers notification actions and schedules the poll timer.
    @ObservationIgnored private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        notifier.center.setNotificationCategories([NotificationManager.deploymentCategory])
        // Default view is "All": every connected provider, and every Vercel team,
        // in one list. `scopeName` stays "all" and the filter is left untouched.
        //
        // Teams load asynchronously, so the first poll only covers the persisted
        // team; `loadTeams` re-polls once the full list arrives (see loadTeams()).
        Task { await poll() }
        Task { await loadTeams() }
        Task { await loadGitHubOrganizations() }
        Task { await loadUser() }
        scheduleTimer()
        observeWake()
    }

    /// The app keeps one store for its whole lifetime, so this never fires in
    /// production — it stops tests (which build a store per case) from leaving
    /// live `Timer`s, wake observers and chained poll tasks behind.
    deinit {
        timer?.invalidate()
        currentPoll?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Refresh as soon as the Mac wakes.
    ///
    /// A `Timer` does not fire while the machine is asleep and does not catch
    /// up afterwards, so without this the first thing seen after opening the
    /// lid is whatever was on screen when it closed — potentially hours stale —
    /// until the next tick comes round.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Restart the interval from the wake instant too, so the next
                // scheduled tick isn't a leftover fraction of the pre-sleep one.
                self.scheduleTimer()
                await self.poll()
            }
        }
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

    /// Tick counter driving the round-robin rotation. Monotonic; only its
    /// remainder matters.
    @ObservationIgnored private var pollTick = 0

    /// Estimated requests one scope costs per poll. GitHub fans out a
    /// workflow-runs request per repository on top of the repo listing, so its
    /// scopes cost several times what a Vercel scope does (one deployments
    /// call, one projects call).
    private func estimatedRequestsPerScope(for account: Account) -> Int {
        switch account.provider {
        case .github:                return 6
        case .vercel, .azureDevOps:  return 2
        }
    }

    /// Provider hourly request ceiling used to size the budget.
    private func hourlyLimit(for account: Account) -> Int {
        switch account.provider {
        case .github:      return 5000     // authenticated REST limit
        // Vercel rate-limits per-endpoint per-minute, far more generously than
        // an hourly figure implies — this is a safety rail against pathological
        // scope counts, not a mirror of a documented quota.
        case .vercel:      return 20000
        case .azureDevOps: return 1000
        }
    }

    /// How often any one of this account's scopes actually refreshes. Equal to
    /// the poll interval until the account has more scopes than one tick can
    /// afford, after which they rotate. Surfaced in Settings.
    func effectiveRefreshInterval(for account: Account) -> Int {
        let count = availableScopes.filter { $0.account.id == account.id }.count
        let budget = ScopePollBudget.requestsPerTick(
            scopeCount: count,
            pollIntervalSeconds: settings.pollIntervalSeconds,
            hourlyLimit: hourlyLimit(for: account),
            requestsPerScope: estimatedRequestsPerScope(for: account))
        return ScopePollBudget.effectiveIntervalSeconds(
            scopeCount: count, budget: budget,
            pollIntervalSeconds: settings.pollIntervalSeconds)
    }

    /// The scopes this tick may fetch: per account, at most what its budget
    /// affords, rotating so every scope comes round in turn.
    private func scopesToPollThisTick() -> [Scope] {
        let byAccount = Dictionary(grouping: availableScopes, by: { $0.account.id })
        return byAccount.flatMap { accountId, scopes -> [Scope] in
            guard let account = account(accountId) else { return [] }
            let budget = ScopePollBudget.requestsPerTick(
                scopeCount: scopes.count,
                pollIntervalSeconds: settings.pollIntervalSeconds,
                hourlyLimit: hourlyLimit(for: account),
                requestsPerScope: estimatedRequestsPerScope(for: account))
            let ids = scopes.map { ScopeRef(accountId: accountId, teamId: $0.teamId).id }
            let chosen = Set(ScopePollBudget.slice(scopeIds: ids, budget: budget, tick: pollTick))
            return scopes.filter {
                chosen.contains(ScopeRef(accountId: accountId, teamId: $0.teamId).id)
            }
        }
    }

    /// Forgets a scope's cached rows so re-enabling it shows fresh data rather
    /// than a snapshot from before it was switched off.
    func scopeEnablementChanged(accountId: UUID, teamId: String?) {
        let ref = ScopeRef(accountId: accountId, teamId: teamId)
        lastGood.removeValue(forKey: ref)
        scopeErrors.removeValue(forKey: ref)
        applyDisplayFilter()
    }

    private struct ScopeResult {
        let account: Account
        /// Vercel team the rows came from; nil for personal / non-Vercel.
        let teamId: String?
        let deployments: [Deployment]
        let projects: [Project]
    }

    /// Refresh every scope.
    ///
    /// Overlapping calls are *coalesced*, not dropped. `switchTeam`/`selectAll`
    /// mutate the active scope and then `await poll()` to fetch it; when the
    /// periodic timer happened to be mid-poll, the old `guard` returned without
    /// fetching and the popover sat on the previous scope's rows — under a new
    /// label — until the next tick (up to the full poll interval). Now the
    /// racing caller waits for the in-flight poll and then gets its own run,
    /// so the data always catches up with the scope the user picked.
    func poll() async {
        // Mid-poll: chain onto the current run so we start only once it is done,
        // and record that chained task so further callers join it rather than
        // stacking a run each.
        if let inFlight = currentPoll {
            let chained = Task { @MainActor [weak self] in
                _ = await inFlight.value
                guard let self else { return }
                await self.runPoll()
            }
            currentPoll = chained
            await chained.value
            if currentPoll == chained { currentPoll = nil }
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPoll()
        }
        currentPoll = task
        await task.value
        if currentPoll == task { currentPoll = nil }
    }

    private func runPoll() async {
        isPollInFlight = true
        isRefreshing = true
        // Whatever the outcome, the first attempt is over — the popover must stop
        // showing "Loading…" even when there is nothing to show.
        defer { isPollInFlight = false; isRefreshing = false; isLoadingInitial = false }

        guard !availableScopes.isEmpty else {
            isLoggedOut = true        // no connected accounts at all
            return
        }

        pollTick &+= 1
        let scopes = scopesToPollThisTick()

        var merged: [ScopeResult] = []
        var errors: [ScopeRef: String] = [:]
        var freshSuccessCount = 0

        // Fan out one fetch per scope, capped to at most maxConcurrentFetches in
        // flight at once. withTaskGroup keeps per-source isolation: one source
        // throwing never cancels the others.
        await withTaskGroup(of: (Scope, Result<([Deployment], [Project]), Error>).self) { group in
            var pending = scopes.makeIterator()
            var inFlight = 0
            // Cap concurrent fetches: 40 organizations opening at once reads to
            // the provider as a burst rather than a poll.
            while inFlight < ScopePollBudget.maxConcurrentFetches, let scope = pending.next() {
                group.addTask { @MainActor in
                    do { return (scope, .success(try await self.fetch(for: scope))) }
                    catch { return (scope, .failure(error)) }
                }
                inFlight += 1
            }

            for await (scope, result) in group {
                if let next = pending.next() {
                    group.addTask { @MainActor in
                        do { return (next, .success(try await self.fetch(for: next))) }
                        catch { return (next, .failure(error)) }
                    }
                }
                let ref = ScopeRef(accountId: scope.account.id, teamId: scope.teamId)
                switch result {
                case .success(let (deps, projs)):
                    consecutiveAuthFailures[ref] = 0
                    freshSuccessCount += 1
                    let res = ScopeResult(account: scope.account, teamId: scope.teamId,
                                          deployments: deps, projects: projs)
                    lastGood[ref] = res
                    merged.append(res)
                case .failure(let error):
                    record(error: error, for: scope, ref: ref, into: &errors)
                    // Keep this source's last-known rows so a transient failure
                    // doesn't blank the menu (mirrors the old "stale" behavior).
                    if let prev = lastGood[ref] { merged.append(prev) }
                }
            }
        }

        // Scopes deferred to a later tick keep their last-known rows, so
        // rotation never blanks a source that is merely waiting its turn.
        let polled = Set(scopes.map { ScopeRef(accountId: $0.account.id, teamId: $0.teamId) })
        for (ref, previous) in lastGood where !polled.contains(ref) {
            guard availableScopes.contains(where: {
                ScopeRef(accountId: $0.account.id, teamId: $0.teamId) == ref
            }) else { continue }
            merged.append(previous)
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
        }.sorted(by: SourcedProject.displayOrder)

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

        self.scopeErrors = errors
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
        // fetch this tick AND every enabled scope is past the auth-failure
        // threshold). Checked against every available scope, not just the ones
        // this tick's budget polled — a scope merely deferred to a later tick
        // must not be mistaken for one that is actually failing auth.
        let allAuthFailing = availableScopes.allSatisfy {
            let ref = ScopeRef(accountId: $0.account.id, teamId: $0.teamId)
            return (consecutiveAuthFailures[ref] ?? 0) >= Self.authFailureThreshold
        }
        isLoggedOut = freshSuccessCount == 0 && allAuthFailing

        // Prune per-account state for accounts that are no longer connected,
        // preventing unbounded growth when accounts are removed.
        let liveIds = Set(accountStore.accounts.map(\.id))
        lastGood = lastGood.filter { liveIds.contains($0.key.accountId) }
        consecutiveAuthFailures = consecutiveAuthFailures.filter { liveIds.contains($0.key.accountId) }
    }

    /// Drop every trace of accounts that are no longer connected, then re-poll.
    ///
    /// Removing a provider is the one moment the project list is *expected* to
    /// change, and the caches all had to be told: `lastGood` would otherwise keep
    /// replaying the removed source's rows on every failed tick, and
    /// `settings.cachedRows` would survive on disk — a poll that fetches nothing
    /// (the removed account was the only source) never overwrites the snapshot,
    /// so the rows would come back at the next launch.
    func accountsChanged() async {
        let live = Set(accountStore.accounts.map(\.id))
        lastGood = lastGood.filter { live.contains($0.key.accountId) }
        consecutiveAuthFailures = consecutiveAuthFailures.filter { live.contains($0.key.accountId) }
        scopeErrors = scopeErrors.filter { live.contains($0.key.accountId) }
        unfilteredDeployments.removeAll { !live.contains($0.account.id) }
        unfilteredProjects.removeAll { !live.contains($0.account.id) }
        // Rewrite the snapshot now rather than waiting for a successful poll,
        // which may never come.
        settings.cachedRows = RowCache(deployments: unfilteredDeployments,
                                       projects: unfilteredProjects,
                                       savedAt: Date())
        applyDisplayFilter()
        await poll()
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
        if legacyAccount == nil, let cli = accountStore.cliAccount {
            teamsClient = TeamsClient(token: fresh, fetch: accountStore.vercelFetch(for: cli))
            userClient = UserClient(token: fresh, fetch: accountStore.vercelFetch(for: cli))
        } else {
            teamsClient = TeamsClient(token: fresh)
            userClient = UserClient(token: fresh)
        }
        return true
    }

    private func record(error: Error, for scope: Scope, ref: ScopeRef,
                        into errors: inout [ScopeRef: String]) {
        // Name the team when there is one, so "reconnect Acme" doesn't leave the
        // user guessing which of an account's teams actually went bad.
        let label = scope.displayLabel
        // Throttling is not an auth failure: leave the counter alone so a long
        // rate-limit window can't be mistaken for a logout, and say what is
        // actually happening instead of "stale".
        if case VercelClientError.rateLimited(let retryAfter) = error {
            if let retryAfter, retryAfter >= 60 {
                let minutes = Int((retryAfter / 60).rounded(.up))
                errors[ref] = "\(label): rate limited — retrying in ~\(minutes) min"
            } else {
                errors[ref] = "\(label): rate limited — retrying shortly"
            }
            return
        }
        if case VercelClientError.unauthorized = error {
            consecutiveAuthFailures[ref, default: 0] += 1
            if (consecutiveAuthFailures[ref] ?? 0) >= Self.authFailureThreshold {
                errors[ref] = "Not logged in — reconnect \(label)"
            }
            // Below threshold: stay quiet, keep last-known rows; the timer retries.
        } else {
            errors[ref] = "Couldn't refresh \(label) (stale)"
        }
    }
}
