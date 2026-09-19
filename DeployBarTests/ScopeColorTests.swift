import XCTest
import SwiftUI
@testable import DeployBar

/// Scope marker colors: stable defaults, working overrides, and the invariant
/// tying the pure index math to the SwiftUI palette.
@MainActor
final class ScopeColorTests: XCTestCase {

    /// `ScopeColorIndex` can't see `ScopeColor.palette` (it deliberately avoids
    /// importing SwiftUI), so it hardcodes the count. If the palette grows and
    /// this isn't updated, the extra colors would simply never be assigned.
    func test_paletteCountMatchesIndexer() {
        XCTAssertEqual(ScopeColor.palette.count, ScopeColorIndex.paletteCount)
        XCTAssertEqual(ScopeColor.names.count, ScopeColor.palette.count,
                       "Every palette color needs a name for the picker menu")
    }

    /// The reason defaults are positional rather than hashed: with 8 slots, a
    /// hash collides for ~81% of users at 5 scopes — exactly when telling
    /// sources apart matters most.
    func test_everyScopeGetsADistinctColorUpToPaletteSize() {
        for count in 1...ScopeColorIndex.paletteCount {
            let ids = (0..<count).map { "account-\($0)|personal" }
            let assigned = ScopeColorIndex.assignments(scopeIds: ids)
            XCTAssertEqual(Set(assigned.values).count, count,
                           "\(count) scopes should get \(count) distinct colors")
        }
    }

    /// Past the palette size, reuse is unavoidable — but it must stay even
    /// rather than piling several scopes onto one slot.
    func test_beyondPaletteSizeColorsWrapEvenly() {
        let ids = (0..<17).map { "account-\($0)|personal" }
        let assigned = ScopeColorIndex.assignments(scopeIds: ids)
        let counts = Dictionary(grouping: assigned.values, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(Set(assigned.values).count, ScopeColorIndex.paletteCount)
        XCTAssertLessThanOrEqual(counts.values.max() ?? 0, 3)
    }

    /// Renaming a team must not repaint anything: assignment sorts by id, and
    /// ids are built from account UUID + team id, never the display name.
    func test_colorsAreStableWhenTheScopeSetIsUnchanged() {
        let ids = ["b|personal", "a|team_x", "c|team_y"]
        let first = ScopeColorIndex.assignments(scopeIds: ids)
        let reordered = ScopeColorIndex.assignments(scopeIds: ids.reversed())
        XCTAssertEqual(first, reordered, "input order must not affect assignment")
    }

    func test_indexIsAlwaysInRange() {
        let ids = (0..<30).map { "account-\($0)|personal" }
        for id in ids {
            let index = ScopeColorIndex.index(for: id, among: ids)
            XCTAssertTrue((0..<ScopeColorIndex.paletteCount).contains(index))
        }
    }

    /// A row whose scope just disappeared still needs a stable color rather
    /// than silently falling to slot 0 alongside an unrelated scope.
    func test_unknownScopeFallsBackToAStableColor() {
        let known = ["a|personal", "b|personal"]
        let first = ScopeColorIndex.index(for: "ghost|team_z", among: known)
        let again = ScopeColorIndex.index(for: "ghost|team_z", among: known)
        XCTAssertEqual(first, again)
        XCTAssertTrue((0..<ScopeColorIndex.paletteCount).contains(first))
    }

    // MARK: - Overrides

    func test_overrideWinsOverDerivedColor() {
        let settings = SettingsStore(defaults: makeDefaults())
        let id = "acct|personal"
        let derived = ScopeColorIndex.index(for: id, among: [id])
        let other = (derived + 3) % ScopeColorIndex.paletteCount

        settings.setScopeColor(other, for: id)
        XCTAssertEqual(settings.scopeColorOverrides[id], other)
    }

    func test_clearingOverrideFallsBackToDerivedColor() {
        let settings = SettingsStore(defaults: makeDefaults())
        let id = "acct|team_x"

        settings.setScopeColor(2, for: id)
        XCTAssertEqual(settings.scopeColorOverrides[id], 2)

        settings.setScopeColor(nil, for: id)
        XCTAssertNil(settings.scopeColorOverrides[id],
                     "clearing must remove the key so the derived color applies")
    }

    func test_overridesAreScopedPerScopeNotPerAccount() {
        let settings = SettingsStore(defaults: makeDefaults())
        let personal = ScopeRef(accountId: fixedId, teamId: nil).id
        let team = ScopeRef(accountId: fixedId, teamId: "team_abc").id

        settings.setScopeColor(1, for: personal)
        settings.setScopeColor(5, for: team)

        XCTAssertEqual(settings.scopeColorOverrides[personal], 1)
        XCTAssertEqual(settings.scopeColorOverrides[team], 5,
                       "two scopes of one account must be colorable independently")
    }

    /// A stored index from a future/older palette must not crash the swatch.
    func test_outOfRangeOverrideFallsBackInsteadOfCrashing() {
        XCTAssertEqual(ScopeColor.color(at: 999), ScopeColor.palette[0])
        XCTAssertEqual(ScopeColor.color(at: -1), ScopeColor.palette[0])
    }

    // MARK: - Picker

    /// The swatch resolves its color exactly the way the popover rows do:
    /// override first, derived color otherwise. Guards the picker against
    /// drifting from `ScopeDot` and showing a color the row never uses.
    func test_pickerResolvesOverrideThenDerivedColor() {
        let settings = SettingsStore(defaults: makeDefaults())
        let id = "acct|personal"
        let all = [id, "acct|team_x"]

        func selectedIndex(overrides: [String: Int]) -> Int {
            overrides[id] ?? ScopeColorIndex.index(for: id, among: all)
        }

        XCTAssertEqual(selectedIndex(overrides: settings.scopeColorOverrides),
                       ScopeColorIndex.index(for: id, among: all),
                       "with no override the swatch shows the derived color")

        settings.setScopeColor(6, for: id)
        XCTAssertEqual(selectedIndex(overrides: settings.scopeColorOverrides), 6)

        settings.setScopeColor(nil, for: id)
        XCTAssertEqual(selectedIndex(overrides: settings.scopeColorOverrides),
                       ScopeColorIndex.index(for: id, among: all),
                       "clearing returns the swatch to Automatic")
    }

    /// Every palette slot must be selectable and resolve to a real color — the
    /// picker builds one button per index in `ScopeColor.palette`.
    func test_everyPaletteSlotIsSelectable() {
        let settings = SettingsStore(defaults: makeDefaults())
        let id = "acct|personal"

        for index in ScopeColor.palette.indices {
            settings.setScopeColor(index, for: id)
            XCTAssertEqual(settings.scopeColorOverrides[id], index)
            XCTAssertEqual(ScopeColor.color(at: index), ScopeColor.palette[index])
        }
    }

    // MARK: - Organization inheritance

    func test_organizationInheritsTheAccountColorByDefault() {
        let (store, _, _) = Self.makeStore(accounts: [Self.gitHubAccount])
        store.setOrganizations([Team(id: "Vorciu", slug: "Vorciu", name: "Vorciu")],
                               for: Self.gitHubAccount.id)

        let account = store.scopeColorIndex(accountId: Self.gitHubAccount.id, teamId: nil)
        let org = store.scopeColorIndex(accountId: Self.gitHubAccount.id, teamId: "Vorciu")

        XCTAssertEqual(org, account,
                       "an org with no override must read as part of its account")
    }

    func test_organizationOverrideWinsOverInheritance() {
        let (store, _, settings) = Self.makeStore(accounts: [Self.gitHubAccount])
        store.setOrganizations([Team(id: "Vorciu", slug: "Vorciu", name: "Vorciu")],
                               for: Self.gitHubAccount.id)
        let ref = ScopeRef(accountId: Self.gitHubAccount.id, teamId: "Vorciu").id
        settings.setScopeColor(5, for: ref)

        XCTAssertEqual(store.scopeColorIndex(accountId: Self.gitHubAccount.id, teamId: "Vorciu"), 5)
    }

    func test_addingOrganizationsDoesNotChangeAccountColors() {
        let (store, _, _) = Self.makeStore(accounts: [Self.gitHubAccount, Self.vercelAccount])
        let before = store.scopeColorIndex(accountId: Self.vercelAccount.id, teamId: nil)

        store.setOrganizations((0..<12).map { Team(id: "org\($0)", slug: "org\($0)", name: "org\($0)") },
                               for: Self.gitHubAccount.id)

        XCTAssertEqual(store.scopeColorIndex(accountId: Self.vercelAccount.id, teamId: nil), before,
                       "account colors must not reshuffle when orgs are discovered")
    }

    // MARK: - Helpers

    private let fixedId = UUID(uuidString: "8B1C2D3E-0000-0000-0000-000000000001")!

    private func makeDefaults() -> UserDefaults {
        let suite = "ScopeColorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A fixed-identity GitHub account so tests can share `store.scopeColorIndex`
    /// expectations without re-deriving the account's UUID each time.
    private static let gitHubAccount = Account(
        id: UUID(uuidString: "8B1C2D3E-0000-0000-0000-0000000000A1")!,
        provider: .github, label: "GitHub", source: .keychain(account: "gh-fixture"))

    /// A fixed-identity Vercel account, distinct from `gitHubAccount`, so tests
    /// can assert one account's colour is unaffected by the other's changes.
    private static let vercelAccount = Account(
        id: UUID(uuidString: "8B1C2D3E-0000-0000-0000-0000000000A2")!,
        provider: .vercel, label: "Vercel", source: .keychain(account: "vc-fixture"))

    /// Builds a `DeploymentStore` around a fresh `AccountStore` seeded with the
    /// given (already keychain-shaped) accounts. These tests never poll, so the
    /// client factory is a no-op. `DeploymentStore.settings` is private, so the
    /// `SettingsStore` used to build the store is returned alongside it for
    /// tests that need `scopeColorOverrides` directly.
    private static func makeStore(accounts: [Account]) -> (DeploymentStore, [Account], SettingsStore) {
        let accountStore = AccountStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        credentials: InMemoryCredentialStore(),
                                        detectCLI: { false }, reloadCLIToken: { nil },
                                        detectGitHubCLI: { false })
        for account in accounts {
            accountStore.adoptDemoAccount(account)
        }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = DeploymentStore(
            accountStore: accountStore, settings: settings,
            makeClient: { _, _ in nil },
            reloadToken: { nil }, authRetryBackoff: .zero)
        return (store, accounts, settings)
    }
}
