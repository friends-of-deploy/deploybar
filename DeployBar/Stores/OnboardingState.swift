import Foundation
import Observation

@MainActor
@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable {
        case welcome, connect, preferences
    }

    var step: Step = .welcome
    @ObservationIgnored private let defaults: UserDefaults
    private static let presentedKey = "hasPresentedOnboarding"
    private static let completedKey = "hasCompletedOnboarding"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isComplete: Bool { defaults.bool(forKey: Self.completedKey) }

    /// Existing installations keep their quiet launch. An unconfigured install
    /// gets one automatic welcome; closing it leaves setup available on demand.
    func shouldPresentAutomatically(hasAccounts: Bool) -> Bool {
        !hasAccounts && !defaults.bool(forKey: Self.presentedKey) && !isComplete
    }

    func markPresented() { defaults.set(true, forKey: Self.presentedKey) }
    func complete() { defaults.set(true, forKey: Self.completedKey) }
}
