import Foundation
import Observation

@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let notifyOnFailure  = "notifyOnFailure"
        static let notifyOnSuccess  = "notifyOnSuccess"
        static let notifyOnStarted  = "notifyOnStarted"
        static let notifyOnCanceled = "notifyOnCanceled"
        static let pollInterval     = "pollIntervalSeconds"
        static let disabledProjects = "disabledProjects"
        static let selectedTeamId   = "selectedTeamId"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.notifyOnFailure:  true,
            Keys.notifyOnSuccess:  true,
            Keys.notifyOnStarted:  false,
            Keys.notifyOnCanceled: false,
            Keys.pollInterval:     30,
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

    /// The user-selected team id, or nil for personal / CLI default.
    /// Stores "__personal__" as a sentinel to distinguish "personal explicitly chosen" from "never set".
    var selectedTeamId: String? {
        get { defaults.string(forKey: Keys.selectedTeamId) }
        set {
            if let newValue { defaults.set(newValue, forKey: Keys.selectedTeamId) }
            else { defaults.removeObject(forKey: Keys.selectedTeamId) }
        }
    }

    // Per-project notifications: opt-out model (all projects enabled by default).
    func isProjectEnabled(_ name: String) -> Bool {
        !(defaults.stringArray(forKey: Keys.disabledProjects) ?? []).contains(name)
    }
    func setProject(_ name: String, enabled: Bool) {
        var disabled = Set(defaults.stringArray(forKey: Keys.disabledProjects) ?? [])
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        defaults.set(Array(disabled), forKey: Keys.disabledProjects)
    }
}
