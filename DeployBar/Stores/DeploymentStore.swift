import AppKit
import Foundation
import Observation
import os

/// What the menu bar glyph shows, including unacknowledged deploy outcomes.
enum IconState: Equatable { case building, success, failure, loggedOut, idle }

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
    /// Which providers this store can talk to, and how.
    @ObservationIgnored let registry: ProviderRegistry

    /// Who each account is signed in as, once asked. Feeds owner labels.
    private(set) var identities: [UUID: AccountIdentity] = [:]

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var accountPollTimes: [UUID: Date] = [:]
    /// Where each account's rotation resumes: the first scope the last tick left out.
    @ObservationIgnored private var accountRotationCursors: [UUID: Int] = [:]
    /// How many by-id in-progress re-reads each account's tick can still afford,
    /// after its chosen scopes' fetches (and, for GitHub, the shared listing).
    /// Rebuilt every tick in `scopesToPollThisTick`; an account gated this tick
    /// has no entry, so it re-reads nothing until its next eligible tick.
    @ObservationIgnored private var inProgressRefreshAllowance: [UUID: Int] = [:]
    @ObservationIgnored private var scopeGenerations: [ScopeRef: Int] = [:]
    @ObservationIgnored private var knownAccountIds: Set<UUID>

    // MARK: Notification baseline (one list across all sources, keyed by uid)
    @ObservationIgnored private var previousSnapshots: [DeploymentSnapshot]?

    // MARK: Polling machinery
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isPollInFlight = false
    /// The poll currently running. Lets `poll()` coalesce racing callers
    /// instead of dropping their request.
    @ObservationIgnored private var currentPoll: Task<Void, Never>?
    /// The single run queued behind `currentPoll`, shared by every caller that
    /// arrives mid-poll.
    @ObservationIgnored private var followUpPoll: Task<Void, Never>?
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

    /// Backoff before the in-poll auth retry. Production 0.8s; tests pass 0.
    @ObservationIgnored private let authRetryBackoff: Duration

    // MARK: Legacy single-scope team switching (CLI/first account only)
    @ObservationIgnored private(set) var currentTeamId: String?

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
         registry: ProviderRegistry,
         now: @escaping () -> Date = Date.init,
         authRetryBackoff: Duration = .milliseconds(800)) {
        self.knownAccountIds = Set(accountStore.accounts.map(\.id))
        self.now = now
        self.accountStore = accountStore
        self.settings = settings
        self.registry = registry
        self.notifier = NotificationManager(settings: settings)
        self.authRetryBackoff = authRetryBackoff
        self.scopeName = "all"

        if let cli = accountStore.cliAccount {
            self.currentTeamId = settings.selectedTeamId == "__personal__" ? nil : settings.selectedTeamId
            // Start from the cached org/team lists so the very first poll already
            // covers known scopes and rows carry real names; account discovery
            // refreshes these lists after startup.
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

        // Seed the replay store as well as the notification baseline: the first
        // budgeted tick may not fetch most of the restored scopes.
        for scope in availableScopes {
            let ref = ScopeRef(accountId: scope.account.id, teamId: scope.teamId)
            let deps = unfilteredDeployments.filter { $0.scope == ref }.map(\.deployment)
            let projs = unfilteredProjects.filter { $0.scope == ref }.map(\.project)
            if !deps.isEmpty || !projs.isEmpty {
                lastGood[ref] = ScopeResult(account: scope.account, teamId: scope.teamId,
                                            deployments: deps, projects: projs)
            }
        }
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

    /// Whether a scope is switched on. Passthrough so views can filter the
    /// menu without reaching through the store into `SettingsStore`.
    func isScopeEnabled(_ ref: ScopeRef) -> Bool {
        settings.isScopeEnabled(ref.id)
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
    /// the user's own username — taken from the account's identity — giving
    /// "konrad-8lines/social" rather than "Vercel CLI/social". The provider's
    /// presentation decides; GitHub repos already carry their owner.
    func projectOwnerLabel(accountId: UUID, teamId: String?) -> String? {
        if let teamId { return teamDisplayName(teamId, accountId: accountId) }
        guard let acct = account(accountId) else { return nil }
        return registry.integration(for: acct.provider)?.presentation.ownerLabel(identities[accountId])
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

    /// Success/failure badges clear when the user opens the popover; a fresh
    /// outcome re-raises them. A running deployment is a live status, never
    /// acknowledged away.
    private var alertAcknowledged = false

    /// Acknowledge the current outcome badge — called when the popover opens.
    func acknowledge() { alertAcknowledged = true }

    var iconState: IconState {
        if isLoggedOut { return .loggedOut }
        let base = Self.baseState(for: sourcedDeployments.map(\.deployment.state))
        if base == .building { return .building }
        if alertAcknowledged { return .idle }
        return base
    }

    /// Pure derivation (no acknowledgment): running > failure > success > idle.
    /// Only a build that is actually running counts — a queued run can wait
    /// indefinitely (GitHub environment approvals), and "deploying" for days
    /// reads as the app being stuck.
    static func baseState(for states: [DeploymentState]) -> IconState {
        if states.contains(.building) { return .building }
        if states.contains(.error) { return .failure }
        if states.contains(.ready) { return .success }
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
    /// report to the clipboard.
    @discardableResult
    func copyBuildError(for deployment: Deployment) async -> Bool {
        guard let sourced = sourced(forDeploymentUid: deployment.uid),
              let integration = registry.integration(for: sourced.account.provider),
              let credential = accountStore.resolve(sourced.account),
              // The team the row was FETCHED from: in "All" that is not
              // necessarily the selected one, and a mismatched team 404s.
              let report = try? await integration.failureReport(for: deployment, teamId: sourced.teamId,
                                                                using: credential)
        else { return false }
        Pasteboard.copy(report)
        return true
    }

    // MARK: - Account organization discovery

    /// The same account-specific discovery path serves startup and account-add.
    func loadOrganizations(for account: Account) async {
        guard let integration = registry.integration(for: account.provider),
              let credential = accountStore.resolve(account) else { return }
        do {
            let fetched = try await integration.organizations(for: account, using: credential)
            guard accountStore.accounts.contains(where: { $0.id == account.id }) else { return }
            let changed = fetched.map(\.id) != organizations(for: account).map(\.id)
            setOrganizations(fetched, for: account.id)
            if changed { await poll() }
        } catch {
            // Keep cached organizations during a transient discovery failure.
            os_log("organization fetch failed for %{public}@: %{public}@", account.label, error.localizedDescription)
        }
    }

    func loadOrganizations() async {
        for account in accountStore.accounts { await loadOrganizations(for: account) }
    }

    /// Asks every account who it is signed in as. One request per account.
    func loadIdentities() async {
        for account in accountStore.accounts { await loadIdentity(for: account) }
    }

    func loadIdentity(for account: Account) async {
        guard let integration = registry.integration(for: account.provider),
              let credential = accountStore.resolve(account),
              let identity = try? await integration.identity(using: credential),
              accountStore.accounts.contains(where: { $0.id == account.id }) else { return }
        identities[account.id] = identity
    }

    func identity(for account: Account) -> AccountIdentity? {
        identities[account.id]
    }

    func setIdentity(_ identity: AccountIdentity?, for accountId: UUID) {
        identities[accountId] = identity
    }

    // MARK: - Scope selection (dropdown)

    /// Select the scope shown in the popover: filters deployments AND projects to
    /// that account (+ team), and for the Vercel CLI account also switches the
    /// polled team.
    func select(accountId: UUID, teamId: String?) async {
        filter = .scope(accountId: accountId, teamId: teamId)
        scopeName = scopeName(accountId: accountId, teamId: teamId) ?? "all"
        if account(accountId)?.source == .vercelCLI, teamId != currentTeamId {
            switchTeam(teamId)
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

    /// Switch the active team for the CLI account at runtime. Records the
    /// choice, persists it, silently re-seeds the notification baseline, and
    /// re-derives the displayed rows from the existing merge.
    ///
    /// No poll here: `availableScopes` fans out to every enabled scope of every
    /// account (see `allScopes(for:)`), not just the CLI account's current team,
    /// so every scope's rows are already being polled and already sit in
    /// `unfilteredDeployments`/`unfilteredProjects`. `currentTeamId` only still
    /// matters in two narrower places — the pre-load fallback in
    /// `allScopes(for:)` for an account whose orgs haven't loaded yet, and
    /// client construction — so changing it here is purely a display-filter
    /// change, and `applyDisplayFilter()` below is sufficient.
    func switchScope(teamId: String?, scopeName: String) async {
        guard teamId != currentTeamId else { return }
        self.scopeName = scopeName
        switchTeam(teamId)
    }

    private func switchTeam(_ teamId: String?) {
        currentTeamId = teamId
        settings.selectedTeamId = teamId ?? "__personal__"
        previousSnapshots = nil               // silent re-seed for the new scope
        scopeErrors = [:]
        // Deliberately NOT clearing the row lists: `applyDisplayFilter` re-derives
        // them from the unfiltered merge, so the popover shows the new scope's
        // known rows immediately instead of flashing empty until the poll lands.
        applyDisplayFilter()
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
        // Discovery joins new organizations into the same budgeted rotation.
        Task { await poll() }
        Task { await loadOrganizations() }
        Task { await loadIdentities() }
        scheduleTimer()
        observeWake()
    }

    /// The app keeps one store for its whole lifetime, so this never fires in
    /// production — it stops tests (which build a store per case) from leaving
    /// live `Timer`s, wake observers and chained poll tasks behind.
    deinit {
        timer?.invalidate()
        currentPoll?.cancel()
        followUpPoll?.cancel()
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

    /// Worst-case requests of one scope's fetch. Sets how often the account
    /// may poll at all (`accountIntervalSeconds`): the costliest scope must fit
    /// one tick. Per-tick packing uses the finer `estimatedCost(of:)`.
    private func estimatedRequestsPerScope(for account: Account) -> Int {
        switch account.provider {
        case .github:                return GitHubClient.maxRequestsPerScope
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
    private func accountPollInterval(for account: Account) -> Int {
        ScopePollBudget.accountIntervalSeconds(
            pollIntervalSeconds: settings.pollIntervalSeconds,
            hourlyLimit: hourlyLimit(for: account),
            requestsPerScope: estimatedRequestsPerScope(for: account))
    }

    func effectiveRefreshInterval(for account: Account) -> Int {
        let scopes = availableScopes.filter { $0.account.id == account.id }
        let interval = accountPollInterval(for: account)
        return interval * ScopePollBudget.ticksPerRotation(
            costs: scopes.map(estimatedCost(of:)),
            budget: requestBudget(for: account, scopes: scopes, interval: interval))
    }

    /// What one scope's fetch is expected to cost, in requests.
    ///
    /// A GitHub organization reads its repositories from the account's shared
    /// listing, reserved once per tick in `requestBudget`, so what is left is
    /// one workflow-runs request per repository, up to the fan-out cap. Its
    /// last result says how many repositories that is. With no result — or
    /// none listed, which a restored cache can't tell from unknown — assume the cap.
    private func estimatedCost(of scope: Scope) -> Int {
        guard scope.account.provider == .github, scope.teamId != nil else {
            return estimatedRequestsPerScope(for: scope.account)
        }
        let ref = ScopeRef(accountId: scope.account.id, teamId: scope.teamId)
        let repositories = lastGood[ref]?.projects.count ?? 0
        return repositories > 0 ? min(repositories, GitHubClient.maxRunRequestsPerScope)
                                : GitHubClient.maxRunRequestsPerScope
    }

    /// This account's share of the hourly limit for one tick, before any
    /// reserve is taken out of it.
    private func tickShare(for account: Account, interval: Int) -> Int {
        ScopePollBudget.tickRequestBudget(pollIntervalSeconds: interval,
                                          hourlyLimit: hourlyLimit(for: account))
    }

    /// The shared GitHub repository listing this tick reserves, given the
    /// scopes it is choosing among (or, for the allowance, the scopes it chose).
    private func listingReserve(for account: Account, scopes: [Scope]) -> Int {
        guard account.provider == .github, scopes.contains(where: { $0.teamId != nil }) else { return 0 }
        return GitHubClient.maxRepoListingRequests
    }

    /// Requests a tick leaves for the account's scope fetches: its share of the
    /// hourly limit (or `share`, the part earned by a poll between ticks), less
    /// what the tick spends besides — the shared GitHub
    /// repository listing and the by-id re-reads of in-progress runs. Packing
    /// still reserves the in-progress re-reads so normal ticks leave them room;
    /// `scopesToPollThisTick` computes the real, post-packing allowance below.
    private func requestBudget(for account: Account, scopes: [Scope], interval: Int,
                               share: Int? = nil) -> Int {
        let tick = share ?? tickShare(for: account, interval: interval)
        guard account.provider == .github else { return tick }
        let inProgress = lastGood.filter { $0.key.accountId == account.id }.values
            .reduce(0) { $0 + $1.deployments.filter(\.state.isInProgress).count }
        return tick - listingReserve(for: account, scopes: scopes) - min(inProgress, Self.maxInProgressRefreshesPerTick)
    }

    /// What a GitHub poll between timer ticks may spend: the tick share,
    /// earned back over the interval since the account's last poll. Nil for a
    /// full tick — the first poll, one at least ~an interval on (timer jitter
    /// allowed), or any other provider.
    ///
    /// Refresh clicks, wakes and scope changes all poll off the timer. Each one
    /// spending a full share took GitHub past 5,000 requests an hour; this way
    /// a click at t+15 s leaves the next tick half a share, and the hour stays
    /// at about one share per interval however often the user refreshes.
    private func offCycleShare(for account: Account, interval: Int, since previous: Date?,
                               at timestamp: Date) -> Int? {
        guard account.provider == .github, let previous else { return nil }
        let elapsed = timestamp.timeIntervalSince(previous)
        guard elapsed < 0.9 * Double(interval) else { return nil }
        return Int(Double(tickShare(for: account, interval: interval)) * max(0, elapsed) / Double(interval))
    }

    /// Only advance an account's rotation when it can actually afford a fetch.
    /// A tick then takes as many scopes, in rotation order, as its budget covers.
    private func scopesToPollThisTick() -> [Scope] {
        inProgressRefreshAllowance = [:]
        let byAccount = Dictionary(grouping: availableScopes, by: { $0.account.id })
        return byAccount.flatMap { accountId, scopes -> [Scope] in
            guard let account = account(accountId) else { return [] }
            let interval = accountPollInterval(for: account)
            let timestamp = now()
            if interval > settings.pollIntervalSeconds,
               let previous = accountPollTimes[accountId],
               timestamp.timeIntervalSince(previous) < Double(interval) { return [] }
            let offCycle = offCycleShare(for: account, interval: interval,
                                         since: accountPollTimes[accountId], at: timestamp)
            accountPollTimes[accountId] = timestamp
            let share = offCycle ?? tickShare(for: account, interval: interval)
            // The first tick starts one past the account scope, where the
            // tick-indexed rotation this replaced began.
            let start = accountRotationCursors[accountId, default: 1] % scopes.count
            let costs = scopes.map(estimatedCost(of:))
            let budget = requestBudget(for: account, scopes: scopes, interval: interval, share: share)
            // A full tick always takes at least one scope; a partial share
            // takes only what it can afford, possibly none.
            let count = offCycle == nil
                ? ScopePollBudget.packedCount(costs: costs, start: start, budget: budget)
                : ScopePollBudget.fittingCount(costs: costs, start: start, budget: budget)
            accountRotationCursors[accountId] = (start + count) % scopes.count
            let chosen = count == scopes.count ? scopes
                                                : (0..<count).map { scopes[(start + $0) % scopes.count] }
            // What this tick actually spent on fetches (plus the listing, if an
            // organization is among them) is fixed now; whatever remains of the
            // account's share is what the in-progress re-reads may spend.
            let spent = listingReserve(for: account, scopes: chosen)
                + (0..<count).reduce(0) { $0 + costs[(start + $1) % scopes.count] }
            inProgressRefreshAllowance[accountId] = max(0, share - spent)
            return chosen
        }
    }

    /// Forgets a scope's cached rows so re-enabling it shows fresh data rather
    /// than a snapshot from before it was switched off.
    func scopeEnablementChanged(accountId: UUID, teamId: String?) {
        let ref = ScopeRef(accountId: accountId, teamId: teamId)
        scopeGenerations[ref, default: 0] += 1
        lastGood.removeValue(forKey: ref)
        unfilteredDeployments.removeAll { $0.scope == ref }
        unfilteredProjects.removeAll { $0.scope == ref }
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
    ///
    /// At most one run waits behind the in-flight one, and every caller that
    /// arrives meanwhile shares it: it starts after all of them asked, so it
    /// serves them all. Queuing one run per caller let a poll slower than the
    /// timer interval build an ever-growing backlog of back-to-back fetches.
    func poll() async {
        if let followUp = followUpPoll {
            await followUp.value
            return
        }
        guard let inFlight = currentPoll else {
            await runCurrentPoll()
            return
        }
        let followUp = Task { @MainActor [weak self] in
            _ = await inFlight.value
            guard let self else { return }
            // Now running: later callers need a newer run than this one.
            self.followUpPoll = nil
            await self.runCurrentPoll()
        }
        followUpPoll = followUp
        await followUp.value
    }

    /// Runs one poll as the in-flight one. Wrapped in a task so follow-ups
    /// can wait on it and a cancelled caller can't cut a poll short.
    private func runCurrentPoll() async {
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

        let scopes = scopesToPollThisTick()
        for integration in registry.all { await integration.beginTick() }
        let generations = scopeGenerations
        var firstSuccessScopes = Set<ScopeRef>()

        var merged: [ScopeResult] = []
        var errors: [ScopeRef: String] = [:]
        var freshSuccessCount = 0
        var freshScopes = Set<ScopeRef>()

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
                guard availableScopes.contains(where: {
                    $0.account.id == ref.accountId && $0.teamId == ref.teamId
                }), scopeGenerations[ref, default: 0] == generations[ref, default: 0] else { continue }
                switch result {
                case .success(let (deps, projs)):
                    consecutiveAuthFailures[ref] = 0
                    freshSuccessCount += 1
                    let res = ScopeResult(account: scope.account, teamId: scope.teamId,
                                          deployments: deps, projects: projs)
                    if lastGood[ref] == nil { firstSuccessScopes.insert(ref) }
                    lastGood[ref] = res
                    freshScopes.insert(ref)
                    merged.append(res)
                case .failure(let error):
                    // The last-known rows are replayed below, like a deferred
                    // scope's, so a transient failure doesn't blank the menu.
                    record(error: error, for: scope, ref: ref, into: &errors)
                }
            }
        }

        // Replayed rows are only as fresh as their scope's last turn — up to
        // ~15 minutes with 30 GitHub organizations. A run captured mid-build
        // would hold the menu bar on "deploying" all that time, so re-read the
        // in-progress ones before replaying.
        await refreshInProgressRows(skipping: freshScopes, generations: generations)

        // Scopes deferred to a later tick, or failing this one, keep their
        // last-known rows, so rotation never blanks a source waiting its turn.
        for (ref, previous) in lastGood where !freshScopes.contains(ref) {
            guard availableScopes.contains(where: {
                ScopeRef(accountId: $0.account.id, teamId: $0.teamId) == ref
            }) else { continue }
            merged.append(previous)
        }

        // A different scope may have been disabled/removed while awaiting the
        // final task-group child, after its own result had already arrived.
        let liveResultScopes = Set(availableScopes.map { ScopeRef(accountId: $0.account.id, teamId: $0.teamId) })
        merged.removeAll { result in
            let ref = ScopeRef(accountId: result.account.id, teamId: result.teamId)
            return !liveResultScopes.contains(ref)
                || scopeGenerations[ref, default: 0] != generations[ref, default: 0]
        }
        errors = errors.filter { liveResultScopes.contains($0.key) }

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
        let snapshots = unfilteredDeployments.map {
            DeploymentSnapshot($0.deployment, key: deploymentKey(for: $0))
        }
        // Each scope gets a silent first-success baseline, even if another
        // rotation slice completed earlier. Cached scopes already have a
        // baseline, so real changes since the cache still raise alerts.
        if previousSnapshots != nil {
            let known = Set(previousSnapshots!.map(\.uid))
            previousSnapshots!.append(contentsOf: unfilteredDeployments
                .filter { firstSuccessScopes.contains($0.scope) }
                .map { DeploymentSnapshot($0.deployment, key: deploymentKey(for: $0)) }
                .filter { !known.contains($0.uid) })
        }
        let transitions = DeploymentDiffer.transitions(previous: previousSnapshots, current: snapshots)
        notifier.handle(transitions)
        previousSnapshots = snapshots

        // A fresh success/failure re-raises the outcome badge the user
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
        // Also drop scopes that no longer exist at all — e.g. a GitHub org the
        // user has left, which vanishes from orgsByAccount but (unlike a
        // disabled scope, evicted by scopeEnablementChanged) was never told to
        // clean up after itself. It can never resurface (the replay loop above
        // guards on `availableScopes.contains`), so left unpruned it would sit
        // in `lastGood` for the process lifetime.
        //
        // Filtering against `availableScopes` is safe for scopes merely
        // deferred to a later tick by the poll budget: the replay loop above
        // already established that a deferred scope is still present in
        // `availableScopes` (only `freshScopes`, the per-tick subset, excludes it),
        // so this prune cannot evict a scope that still needs its `lastGood`
        // replayed next tick.
        let liveScopes = Set(availableScopes.map { ScopeRef(accountId: $0.account.id, teamId: $0.teamId) })
        lastGood = lastGood.filter { liveIds.contains($0.key.accountId) && liveScopes.contains($0.key) }
        consecutiveAuthFailures = consecutiveAuthFailures.filter { liveIds.contains($0.key.accountId) }
        accountPollTimes = accountPollTimes.filter { liveIds.contains($0.key) }
        accountRotationCursors = accountRotationCursors.filter { liveIds.contains($0.key) }
        inProgressRefreshAllowance = inProgressRefreshAllowance.filter { liveIds.contains($0.key) }
    }

    /// Upper bound on by-id re-reads per tick. Each costs one request, so a
    /// burst of parallel CI runs can't blow through the provider's budget; any
    /// beyond the cap still refresh when their scope comes round.
    private static let maxInProgressRefreshesPerTick = 10

    /// Re-reads, by id, the in-progress rows of every scope with no fresh
    /// result this tick, and patches `lastGood` so the replay shows real state.
    /// Best-effort: a failed re-read keeps the last-known row.
    ///
    /// Bounded twice over: the global cap guards against a burst of parallel
    /// CI runs blowing through the provider's budget regardless of account,
    /// and each account's `inProgressRefreshAllowance` — what its own tick's
    /// share has left after its chosen scopes' fetches — keeps a tick that
    /// spent most of its share on one costly scope (the personal scope, say)
    /// from adding unbudgeted re-reads on top.
    private func refreshInProgressRows(skipping fresh: Set<ScopeRef>,
                                       generations: [ScopeRef: Int]) async {
        var remaining = Self.maxInProgressRefreshesPerTick
        var allowance = inProgressRefreshAllowance
        var work: [(ref: ScopeRef, client: DeploymentProviderClient, rows: [Deployment])] = []
        for scope in availableScopes where remaining > 0 {
            let ref = ScopeRef(accountId: scope.account.id, teamId: scope.teamId)
            let accountAllowance = allowance[ref.accountId] ?? 0
            guard accountAllowance > 0,
                  !fresh.contains(ref),
                  let live = lastGood[ref]?.deployments.filter({ $0.state.isInProgress }),
                  !live.isEmpty,
                  let client = makeClient(for: scope) else { continue }
            let rows = Array(live.prefix(min(remaining, accountAllowance)))
            remaining -= rows.count
            allowance[ref.accountId] = accountAllowance - rows.count
            work.append((ref, client, rows))
        }
        guard !work.isEmpty else { return }

        let results = await withTaskGroup(of: (ScopeRef, [Deployment]).self) { group in
            for item in work {
                group.addTask {
                    do { return (item.ref, try await item.client.refreshed(item.rows)) }
                    catch {
                        os_log("in-progress refresh failed: %{public}@", error.localizedDescription)
                        return (item.ref, [])
                    }
                }
            }
            return await group.reduce(into: [(ScopeRef, [Deployment])]()) { $0.append($1) }
        }

        for (ref, updates) in results where !updates.isEmpty {
            // The scope may have been disabled or re-enabled while we awaited.
            guard scopeGenerations[ref, default: 0] == generations[ref, default: 0],
                  let previous = lastGood[ref] else { continue }
            let byUid = Dictionary(updates.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
            lastGood[ref] = ScopeResult(account: previous.account, teamId: previous.teamId,
                                        deployments: previous.deployments.map { byUid[$0.uid] ?? $0 },
                                        projects: previous.projects)
        }
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
        let added = live.subtracting(knownAccountIds)
        knownAccountIds = live
        lastGood = lastGood.filter { live.contains($0.key.accountId) }
        consecutiveAuthFailures = consecutiveAuthFailures.filter { live.contains($0.key.accountId) }
        scopeErrors = scopeErrors.filter { live.contains($0.key.accountId) }
        identities = identities.filter { live.contains($0.key) }
        unfilteredDeployments.removeAll { !live.contains($0.account.id) }
        unfilteredProjects.removeAll { !live.contains($0.account.id) }
        // Rewrite the snapshot now rather than waiting for a successful poll,
        // which may never come.
        settings.cachedRows = RowCache(deployments: unfilteredDeployments,
                                       projects: unfilteredProjects,
                                       savedAt: Date())
        applyDisplayFilter()
        for account in accountStore.accounts where added.contains(account.id) {
            await loadOrganizations(for: account)
            await loadIdentity(for: account)
        }
        await poll()
    }

    /// Apply the follow filter + active ScopeFilter to the unfiltered merge.
    ///
    /// Also re-checks scope enablement here, not just at poll time: disabling a
    /// scope evicts it from `lastGood` (see `scopeEnablementChanged`), but that
    /// alone doesn't touch `unfilteredDeployments`/`unfilteredProjects` — those
    /// are only rebuilt by the next `runPoll()`. Without this check, a just-
    /// disabled scope's rows would keep showing in the merged view (and could
    /// keep notifying) until the next poll happened to leave them out.
    private func applyDisplayFilter() {
        sourcedDeployments = unfilteredDeployments.filter { sd in
            filter.matches(account: sd.account, teamId: sd.teamId)
                && isScopeEnabled(sd.scope)
                && followed(account: sd.account, projectId: projectId(for: sd), projectName: sd.deployment.name)
        }
        sourcedProjects = unfilteredProjects.filter { sp in
            filter.matches(account: sp.account, teamId: sp.teamId)
                && isScopeEnabled(sp.scope)
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

    /// A client for one scope, or nil when its provider has no integration or
    /// its account has no usable credential. Both are skipped silently.
    private func makeClient(for scope: Scope) -> DeploymentProviderClient? {
        makeClientAndCredential(for: scope)?.client
    }

    /// The client plus the credential it was built with, so a 401 can be
    /// judged against the token that was actually rejected.
    private func makeClientAndCredential(for scope: Scope)
        -> (client: DeploymentProviderClient, credential: ResolvedCredential)? {
        guard let integration = registry.integration(for: scope.account.provider),
              let credential = accountStore.resolve(scope.account),
              let client = integration.client(for: scope, using: credential) else { return nil }
        return (client, credential)
    }

    private func fetch(for scope: Scope) async throws -> ([Deployment], [Project]) {
        guard let (client, credential) = makeClientAndCredential(for: scope) else {
            return ([], [])          // no integration or no credential → skip silently
        }
        do {
            async let deps = client.deployments(limit: 100)
            async let projs = client.projects()
            return try await (deps, projs)
        } catch ProviderClientError.unauthorized {
            // One retry. A source that has rotated its token since this client
            // was built (the Vercel CLI) gets a fresh client at once; anything
            // else waits out a transient blip and tries the same client again.
            let retryClient: DeploymentProviderClient
            switch accountStore.recoverFromUnauthorized(scope.account, rejectedToken: credential.token) {
            case .retryWithFreshClient:
                retryClient = makeClient(for: scope) ?? client
            case .retryAfterBackoff:
                try? await Task.sleep(for: authRetryBackoff)
                retryClient = client
            }
            async let deps = retryClient.deployments(limit: 100)
            async let projs = retryClient.projects()
            return try await (deps, projs)
        }
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
