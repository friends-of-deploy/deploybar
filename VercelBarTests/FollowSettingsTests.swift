import XCTest
@testable import VercelBar

final class FollowSettingsTests: XCTestCase {
    private func fresh() -> SettingsStore { SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!) }
    private func key(_ pid: String, _ acct: UUID = UUID()) -> ProjectKey {
        ProjectKey(provider: .vercel, accountId: acct, projectId: pid)
    }

    func test_autoFollow_defaultsOn() {
        XCTAssertTrue(fresh().autoFollowNewProjects)
    }

    func test_unknownProject_followedWhenAutoFollowOn() {
        let s = fresh()
        XCTAssertTrue(s.isFollowed(key("new")))
    }

    func test_explicitUnfollow_hidesEvenWithAutoFollowOn() {
        let s = fresh(); let k = key("p")
        s.setFollowed(k, false)
        XCTAssertFalse(s.isFollowed(k))
    }

    func test_autoFollowOff_unknownNotFollowed_butExplicitFollowedShown() {
        let s = fresh(); s.autoFollowNewProjects = false
        let known = key("known"); let unknown = key("unknown")
        s.setFollowed(known, true)
        XCTAssertTrue(s.isFollowed(known))
        XCTAssertFalse(s.isFollowed(unknown))
    }

    func test_followToggleIsIndependentPerKey() {
        let s = fresh(); let acct = UUID()
        let a = key("a", acct); let b = key("b", acct)
        s.setFollowed(a, false)
        XCTAssertFalse(s.isFollowed(a))
        XCTAssertTrue(s.isFollowed(b))
    }
}
