import XCTest
@testable import VercelBar

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
        s.migrateLegacyFollowData(cliAccountId: UUID())
        // Re-running with a different account must NOT re-import (already migrated).
        let other = UUID()
        s.migrateLegacyFollowData(cliAccountId: other)
        XCTAssertTrue(s.isFollowed(ProjectKey(provider: .vercel, accountId: other, projectId: "x")))
    }
}
