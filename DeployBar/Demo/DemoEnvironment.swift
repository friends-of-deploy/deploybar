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

    static func build(scenario: DemoScenario, clock: DemoClock) -> Built {
        let suite = "io.eightlines.deploybar.demo.\(UUID().uuidString)"
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
}
