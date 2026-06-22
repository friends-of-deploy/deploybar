import XCTest
@testable import VercelBar

@MainActor
final class UserLoadingTests: XCTestCase {
    func test_loadUserPopulatesUser() async throws {
        let userData = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "user", withExtension: "json")))
        let depData = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "deployments", withExtension: "json")))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let factory: (VercelCredentials) -> VercelClient = { creds in
            VercelClient(credentials: creds) { req in
                ((req.url!.path.contains("deployments") ? depData : Data(#"{"projects":[]}"#.utf8)),
                 HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let userClient = UserClient(token: "t") { req in
            (userData, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let store = DeploymentStore(client: factory(.init(token: "t", teamId: nil)),
                                    settings: settings, scopeName: "personal",
                                    makeClient: factory, userClient: userClient)
        await store.loadUser()
        XCTAssertNotNil(store.user)
        XCTAssertFalse(store.user!.username.isEmpty)
    }
}
