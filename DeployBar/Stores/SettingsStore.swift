import Foundation
import Observation

/// Main-actor bound, as the `updateChannelDefaultsKey` comment below already
/// assumed: every caller (the stores, the views, Sparkle's `@MainActor`
/// delegate) is on the main actor, and stating it makes an `@Observable`
/// class's isolation explicit rather than inferred.
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// The defaults key for the update channel, exposed because Sparkle's
    /// updater delegate is `nonisolated` and reads the preference directly
    /// rather than through this `@MainActor`-bound store.
    nonisolated static let updateChannelDefaultsKey = "updateChannel"

    private enum Keys {
        static let notifyOnFailure  = "notifyOnFailure"
        static let notifyOnSuccess  = "notifyOnSuccess"
        static let notifyOnStarted  = "notifyOnStarted"
        static let notifyOnCanceled = "notifyOnCanceled"
        static let pollInterval     = "pollIntervalSeconds"
        static let disabledProjects = "disabledProjects"
        static let selectedTeamId   = "selectedTeamId"
        static let followedKeys     = "followedProjectKeys"
        static let unfollowedKeys   = "unfollowedProjectKeys"
        static let mutedNotificationKeys = "mutedNotificationProjectKeys"
        static let autoFollowNew    = "autoFollowNewProjects"
        static let didMigrateFollow = "didMigrateFollowData"
        static let cachedTeams      = "cachedTeams"
        static let cachedRows       = "cachedRows"
        static let scopeColors      = "scopeColorOverrides"
        static let updateChannel    = SettingsStore.updateChannelDefaultsKey
        static let disabledScopes   = "disabledScopeIds"
        static let cachedOrgs       = "cachedOrgsByAccount"
        static let didMigrateOrgs   = "didMigrateCachedTeams"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.notifyOnFailure:  true,
            Keys.notifyOnSuccess:  true,
            Keys.notifyOnStarted:  false,
            Keys.notifyOnCanceled: false,
            Keys.pollInterval:     30,
            Keys.autoFollowNew:    true,
        ])
    }

    var notifyOnFailure: Bool {
        get { defaults.bool(forKey: Keys.notifyOnFailure) }
        set { defaults.set(newValue, forKey: Keys.notifyOnFailure) }
    }
    var notifyOnSuccess: Bool {
        get { defaults.bool(forKey: Keys.notifyOnSuccess) }
        set { defaults.set(newValue, forKey: Keys.notifyOnSuccess) }
    }
    var notifyOnStarted: Bool {
        get { defaults.bool(forKey: Keys.notifyOnStarted) }
        set { defaults.set(newValue, forKey: Keys.notifyOnStarted) }
    }
    var notifyOnCanceled: Bool {
        get { defaults.bool(forKey: Keys.notifyOnCanceled) }
        set { defaults.set(newValue, forKey: Keys.notifyOnCanceled) }
    }
    var pollIntervalSeconds: Int {
        get { max(10, defaults.integer(forKey: Keys.pollInterval)) }
        set { defaults.set(max(10, newValue), forKey: Keys.pollInterval) }
    }

    /// Which release stream this install follows.
    ///
    /// Sparkle's own preferences (automatic checks, automatic downloads, last
    /// check time) are left in Sparkle's hands in this same defaults domain —
    /// mirroring them here would give the Updates tab two sources of truth.
    var updateChannel: UpdateChannel {
        get { UpdateChannel.from(storedValue: defaults.string(forKey: Keys.updateChannel)) }
        set { defaults.set(newValue.rawValue, forKey: Keys.updateChannel) }
    }

    /// The user-selected team id, or nil for personal / CLI default.
    /// Stores "__personal__" as a sentinel to distinguish "personal explicitly chosen" from "never set".
    var selectedTeamId: String? {
        get { defaults.string(forKey: Keys.selectedTeamId) }
        set {
            if let newValue { defaults.set(newValue, forKey: Keys.selectedTeamId) }
            else { defaults.removeObject(forKey: Keys.selectedTeamId) }
        }
    }

    /// Last known Vercel team list, cached so a relaunch can label scopes and
    /// poll every team immediately, instead of waiting on `/v2/teams`. Refreshed
    /// on every successful fetch; the network response always wins.
    var cachedTeams: [Team] {
        get {
            guard let data = defaults.data(forKey: Keys.cachedTeams),
                  let teams = try? JSONDecoder().decode([Team].self, from: data)
            else { return [] }
            return teams
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.cachedTeams)
        }
    }

    /// Last successful poll's rows, replayed on launch so the popover isn't empty
    /// while the first fetch runs. Best-effort: a decode failure just means a cold start.
    var cachedRows: RowCache {
        get {
            guard let data = defaults.data(forKey: Keys.cachedRows),
                  let cache = try? JSONDecoder().decode(RowCache.self, from: data)
            else { return RowCache() }
            return cache
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.cachedRows)
        }
    }

    // MARK: - Scope colors

    /// User-chosen palette slots, keyed by `ScopeRef.id`. Scopes absent here use
    /// the color derived from their id, so this stays empty until someone
    /// actually overrides something.
    var scopeColorOverrides: [String: Int] {
        get { defaults.dictionary(forKey: Keys.scopeColors) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.scopeColors) }
    }

    /// Assigns a palette slot to a scope, or clears the override when `index`
    /// is nil so the scope falls back to its derived color.
    func setScopeColor(_ index: Int?, for scopeId: String) {
        var overrides = scopeColorOverrides
        if let index { overrides[scopeId] = index } else { overrides.removeValue(forKey: scopeId) }
        scopeColorOverrides = overrides
    }

    // MARK: - Scope enablement

    /// Scopes the user has switched off, keyed by `ScopeRef.id`.
    ///
    /// Stores the *disabled* ones rather than the enabled ones so a newly
    /// discovered organization defaults to on: an account that joins a team
    /// should start showing it, not hide it until someone goes looking.
    var disabledScopeIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.disabledScopes) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.disabledScopes) }
    }

    func isScopeEnabled(_ scopeId: String) -> Bool {
        !disabledScopeIds.contains(scopeId)
    }

    func setScopeEnabled(_ enabled: Bool, for scopeId: String) {
        var ids = disabledScopeIds
        if enabled { ids.remove(scopeId) } else { ids.insert(scopeId) }
        disabledScopeIds = ids
    }

    // MARK: - Cached organizations

    /// Last known organization list per account, so a relaunch can label and
    /// poll every scope immediately instead of waiting on the network. Same
    /// contract as `cachedTeams`, which it supersedes: the response always wins.
    var cachedOrgs: [UUID: [Team]] {
        get {
            guard let data = defaults.data(forKey: Keys.cachedOrgs),
                  let decoded = try? JSONDecoder().decode([String: [Team]].self, from: data)
            else { return [:] }
            return decoded.reduce(into: [UUID: [Team]]()) { result, pair in
                if let id = UUID(uuidString: pair.key) { result[id] = pair.value }
            }
        }
        set {
            let keyed = newValue.reduce(into: [String: [Team]]()) { result, pair in
                result[pair.key.uuidString] = pair.value
            }
            guard let data = try? JSONEncoder().encode(keyed) else { return }
            defaults.set(data, forKey: Keys.cachedOrgs)
        }
    }

    /// One-time move of the old single-account `cachedTeams` list into the
    /// per-account `cachedOrgs` map. Guarded so a later real fetch is never
    /// overwritten by the legacy value.
    func migrateCachedTeams(cliAccountId: UUID) {
        guard !defaults.bool(forKey: Keys.didMigrateOrgs) else { return }
        let legacy = cachedTeams
        if !legacy.isEmpty {
            var orgs = cachedOrgs
            orgs[cliAccountId] = legacy
            cachedOrgs = orgs
        }
        defaults.set(true, forKey: Keys.didMigrateOrgs)
    }

    // MARK: - Follow API

    var autoFollowNewProjects: Bool {
        get { defaults.bool(forKey: Keys.autoFollowNew) }
        set { defaults.set(newValue, forKey: Keys.autoFollowNew) }
    }

    private func storedSet(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
    private func store(_ set: Set<String>, _ key: String) {
        defaults.set(Array(set), forKey: key)
    }

    func isFollowed(_ key: ProjectKey) -> Bool {
        let s = key.storageString
        if storedSet(Keys.unfollowedKeys).contains(s) { return false }
        if storedSet(Keys.followedKeys).contains(s) { return true }
        return autoFollowNewProjects
    }

    func setFollowed(_ key: ProjectKey, _ followed: Bool) {
        let s = key.storageString
        var followedSet = storedSet(Keys.followedKeys)
        var unfollowedSet = storedSet(Keys.unfollowedKeys)
        if followed { followedSet.insert(s); unfollowedSet.remove(s) }
        else        { unfollowedSet.insert(s); followedSet.remove(s) }
        store(followedSet, Keys.followedKeys)
        store(unfollowedSet, Keys.unfollowedKeys)
    }

    func areNotificationsMuted(for key: ProjectKey) -> Bool {
        storedSet(Keys.mutedNotificationKeys).contains(key.storageString)
    }

    func setNotificationsMuted(_ muted: Bool, for key: ProjectKey) {
        var keys = storedSet(Keys.mutedNotificationKeys)
        if muted { keys.insert(key.storageString) }
        else { keys.remove(key.storageString) }
        store(keys, Keys.mutedNotificationKeys)
    }

    /// One-time import of the old `disabledProjects` (name-keyed) into the new
    /// unfollowed set under the CLI account. Idempotent via a guard flag.
    func migrateLegacyFollowData(cliAccountId: UUID) {
        guard !defaults.bool(forKey: Keys.didMigrateFollow) else { return }
        let legacyNames = defaults.stringArray(forKey: Keys.disabledProjects) ?? []
        var unfollowedSet = storedSet(Keys.unfollowedKeys)
        for name in legacyNames {
            let key = ProjectKey(provider: .vercel, accountId: cliAccountId, projectId: name)
            unfollowedSet.insert(key.storageString)
        }
        store(unfollowedSet, Keys.unfollowedKeys)
        defaults.removeObject(forKey: Keys.disabledProjects)
        defaults.set(true, forKey: Keys.didMigrateFollow)
    }
}
