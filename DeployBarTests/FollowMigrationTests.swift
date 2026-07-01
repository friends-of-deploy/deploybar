import XCTest
@testable import DeployBar

final class FollowMigrationTests: XCTestCase {
    func test_disabledProjectsMigrateToUnfollowed() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        d.set(["legacy-web", "legacy-api"], forKey: "disabledProjects")
        let s = SettingsStore(defaults: d)
        let cli = UUID()
        s.migrateLegacyFollowData(cliAccountId: cli)

        // Legacy disabled projects were keyed by NAME; migration stores them as
        // unfollowed under the CLI account using the project NAME as projectId,
        // so a project whose id == its name stays unfollowed. (Vercel rows use id;
        // see implementer note.)
        let web = ProjectKey(provider: .vercel, accountId: cli, projectId: "legacy-web")
        XCTAssertFalse(s.isFollowed(web))
        // disabledProjects key is cleared after migration:
        XCTAssertNil(d.array(forKey: "disabledProjects"))
    }

    func test_migrationRunsOnlyOnce() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        d.set(["x"], forKey: "disabledProjects")
        let s = SettingsStore(defaults: d)
        s.migrateLegacyFollowData(cliAccountId: UUID())   // first call; consumes disabledProjects, sets guard
        d.set(["x"], forKey: "disabledProjects")           // re-arm legacy data
        let other = UUID()
        s.migrateLegacyFollowData(cliAccountId: other)     // second call must be a no-op due to the guard
        // If the guard works, "x" was NOT imported under `other`, so auto-follow (default on) makes it followed:
        XCTAssertTrue(s.isFollowed(ProjectKey(provider: .vercel, accountId: other, projectId: "x")))
    }
}
