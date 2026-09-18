import Foundation

/// Builds the isolated world demo mode runs inside.
///
/// Isolation is the point: stores sit on a throwaway `UserDefaults` suite and an
/// `InMemoryCredentialStore`, so the maintainer's real accounts, follow choices
/// and settings are never touched and every run starts from the same state —
/// which is what makes screenshots comparable across releases.
@MainActor
enum DemoEnvironment {

    struct Built {
        let settings: SettingsStore
        let accountStore: AccountStore
        let makeClient: ClientFactory
        /// Assigned to `DeploymentStore.teams` by the caller so the scope picker
        /// shows team scopes. `availableScopes` expands teams only for a
        /// `.vercelCLI` account with a non-empty list.
        let teams: [Team]
    }

    // MARK: - Environment flags

    static func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["DEPLOYBAR_DEMO"] == "1"
    }

    static var isEnabled: Bool { isEnabled() }

    static func buildFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Built? {
        guard isEnabled(in: environment) else { return nil }

        let name = environment["DEPLOYBAR_DEMO_SCENARIO"] ?? "default"
        guard let scenario = try? DemoScenarioLoader.load(named: name) else {
            assertionFailure("demo scenario '\(name)' failed to load")
            return nil
        }
        let clock: DemoClock = environment["DEPLOYBAR_DEMO_FREEZE"] == "1" ? .frozen() : .live()
        return build(scenario: scenario, clock: clock)
    }

    // MARK: - Construction

    /// Shared prefix for every demo suite name, so a plist on disk can be
    /// recognized as "ours" without also matching the app's real domain.
    private static let suitePrefix = "io.eightlines.deploybar.demo."

    static func build(scenario: DemoScenario, clock: DemoClock) -> Built {
        reapStaleSuites()

        let suite = "\(suitePrefix)\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        let accountStore = AccountStore(defaults: defaults,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false },
                                        reloadCLIToken: { nil },
                                        detectGitHubCLI: { false },
                                        reloadGitHubToken: { nil })

        // Seed one account per scenario account, remembering which fixture key
        // each minted UUID came from so the factory can route by scope.
        var keyForAccountId: [UUID: String] = [:]
        for fixture in scenario.accounts {
            let account: Account
            switch fixture.sourceKind {
            case .vercelCLI:
                account = .vercelCLI(id: UUID(), label: fixture.label)
                accountStore.adoptDemoAccount(account)
            case .githubCLI:
                account = .githubCLI(id: UUID(), label: fixture.label)
                accountStore.adoptDemoAccount(account)
            case .keychain:
                account = accountStore.addKeychainAccount(provider: fixture.provider,
                                                          label: fixture.label,
                                                          token: "demo-token")
            }
            keyForAccountId[account.id] = fixture.key
        }

        // Follow state, applied through the normal API so the Projects tab reads
        // it exactly as it would in production.
        for project in scenario.projects {
            guard let account = accountStore.accounts.first(where: {
                keyForAccountId[$0.id] == project.accountKey
            }) else { continue }
            settings.setFollowed(ProjectKey(provider: account.provider,
                                            accountId: account.id,
                                            projectId: project.id),
                                 project.followed)
        }

        let teams = scenario.accounts
            .first { $0.sourceKind == .vercelCLI }?
            .teams
            .map { Team(id: $0.id, slug: $0.slug, name: $0.name) } ?? []

        let makeClient: ClientFactory = { account, teamId in
            guard let key = keyForAccountId[account.id] else { return nil }
            return DemoProviderClient(scenario: scenario, accountKey: key,
                                      teamId: teamId, clock: clock)
        }

        return Built(settings: settings, accountStore: accountStore,
                     makeClient: makeClient, teams: teams)
    }

    // MARK: - Housekeeping

    /// Removes `UserDefaults` persistent domains left behind by earlier demo
    /// runs.
    ///
    /// Isolation and cleanup are independent axes. A UUID-named suite is
    /// always created empty, so the "every run starts from the same state"
    /// guarantee only requires that a run *starts* clean — never that the
    /// suite survives. But the app keeps using the `settings`/`accountStore`
    /// returned by `build` live for the whole session, so the *current* run's
    /// suite can't be torn down from inside `build` itself. Reaping *previous*
    /// runs' suites on the way in is therefore the right shape: it's
    /// self-healing, needs no app-lifecycle hook, and covers both test runs
    /// and real launches the same way.
    ///
    /// Best-effort: a failure to enumerate `~/Library/Preferences` is
    /// housekeeping trivia, not a reason to block demo startup.
    ///
    /// `removePersistentDomain(forName:)` clears the domain from
    /// `UserDefaults`/`cfprefsd`'s cache, which is what actually matters:
    /// without it, a later read through `UserDefaults(suiteName:)` for the
    /// same reused name (however unlikely with a UUID) could resurrect the
    /// stale values from the cache. But it does not reliably delete the
    /// backing plist on disk — that write-back is async and owned by
    /// `cfprefsd`, so the file the maintainer actually sees littering
    /// `~/Library/Preferences` can outlive the call. The file is therefore
    /// also removed directly.
    private static func reapStaleSuites() {
        let preferencesDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Preferences")
        guard let preferencesDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: preferencesDirectory.path)
        else { return }

        for filename in contents where filename.hasPrefix(suitePrefix) && filename.hasSuffix(".plist") {
            let domain = String(filename.dropLast(".plist".count))
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: preferencesDirectory.appendingPathComponent(filename))
        }
    }
}
