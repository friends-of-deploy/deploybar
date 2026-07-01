import XCTest
@testable import DeployBar

final class CredentialStoreTests: XCTestCase {
    func test_inMemory_roundTrip() {
        let store = InMemoryCredentialStore()
        XCTAssertNil(store.token(for: "a"))
        store.setToken("secret", for: "a")
        XCTAssertEqual(store.token(for: "a"), "secret")
        store.removeToken(for: "a")
        XCTAssertNil(store.token(for: "a"))
    }

    func test_inMemory_keysAreIndependent() {
        let store = InMemoryCredentialStore()
        store.setToken("one", for: "a")
        store.setToken("two", for: "b")
        XCTAssertEqual(store.token(for: "a"), "one")
        XCTAssertEqual(store.token(for: "b"), "two")
    }

    func test_keychain_roundTrip() {
        // Uses a unique service name so the test never collides with real app creds.
        let store = KeychainCredentialStore(service: "io.eightlines.deploybar.test.\(UUID().uuidString)")
        let acct = "kc-test"
        store.removeToken(for: acct)
        XCTAssertNil(store.token(for: acct))
        store.setToken("tok-123", for: acct)
        XCTAssertEqual(store.token(for: acct), "tok-123")
        store.setToken("tok-456", for: acct)   // overwrite
        XCTAssertEqual(store.token(for: acct), "tok-456")
        store.removeToken(for: acct)
        XCTAssertNil(store.token(for: acct))
    }
}
