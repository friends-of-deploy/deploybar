# Multi-Provider Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape VercelBar so "Vercel" is one provider group among future ones, with multi-account support (Keychain + CLI), a grouped provider→account→team filter dropdown, and an explicit "followed projects" concept (default: follow all new). Only Vercel ships working.

**Architecture:** Introduce `Provider`/`Account`/`Scope` value types and a `DeploymentProviderClient` protocol that `VercelClient` conforms to. An `AccountStore` owns connected accounts and secrets (via an injectable `CredentialStore`/Keychain). `DeploymentStore` becomes a multi-scope aggregator that fans out per followed scope, tags results by account, merges, filters, and isolates per-source errors. `SettingsStore` gains a composite-keyed follow API and migrates the old `disabledProjects`/`selectedTeamId` data.

**Tech Stack:** Swift 5, SwiftUI, Observation (`@Observable`), XCTest, XcodeGen (`project.yml`), macOS 14 deployment target.

## Global Constraints

- macOS deployment target: **14.0** — do not use APIs introduced after macOS 14. (project.yml)
- `SWIFT_VERSION: "5.0"`, `SWIFT_STRICT_CONCURRENCY: minimal`. (project.yml)
- Tests use **XCTest** (`import XCTest`, `@testable import VercelBar`), not Swift Testing. Async store tests are `@MainActor final class … XCTestCase`.
- New source files under `VercelBar/` are picked up automatically by XcodeGen's `sources: [VercelBar]` glob; new test files under `VercelBarTests/` likewise. **After adding files, regenerate the project:** `xcodegen generate`.
- Fixtures live in `VercelBarTests/Fixtures/` and are bundled as resources; load with `Bundle(for: Self.self).url(forResource:withExtension:)`.
- Networked clients inject a `fetch: (URLRequest) async throws -> (Data, URLResponse)` closure for testing — follow this pattern for any new networked type.
- Build/test command (run after `xcodegen generate`):
  ```bash
  xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' test 2>&1 | xcbeautify
  ```
  If `xcbeautify` is unavailable, drop the pipe. To run a single test class add `-only-testing:VercelBarTests/<ClassName>`.
- Localize user-facing strings with `String(localized:comment:)` (project supports en + pl).
- `DeploymentState`, `Deployment`, `Project`, `Team`, `VercelUser`, `StateTransition`/`DeploymentSnapshot`, `DeploymentEvent` already exist — reuse them; do not redefine.

---

## File Structure

**New source files:**
- `VercelBar/Models/Provider.swift` — `Provider` enum + presentation metadata.
- `VercelBar/Models/Account.swift` — `Account`, `CredentialSource`.
- `VercelBar/Models/Scope.swift` — `Scope` (account + optional team), `ScopeFilter`.
- `VercelBar/Models/SourcedItem.swift` — `SourcedDeployment`, `SourcedProject` (a result tagged with its `Account`).
- `VercelBar/Models/ProjectFollow.swift` — `ProjectKey` composite identity + helpers.
- `VercelBar/Clients/DeploymentProviderClient.swift` — protocol + `VercelClient` conformance (extension).
- `VercelBar/Services/CredentialStore.swift` — `CredentialStore` protocol + `KeychainCredentialStore` + `InMemoryCredentialStore`.
- `VercelBar/Stores/AccountStore.swift` — owns connected accounts; CLI detection; add/remove; secret IO.

**Modified source files:**
- `VercelBar/Stores/SettingsStore.swift` — follow API + auto-follow flag + migration; drop `disabledProjects`/`selectedTeamId` usage (keep reading them for migration).
- `VercelBar/Stores/DeploymentStore.swift` — multi-scope aggregator.
- `VercelBar/Stores/DeploymentDiffer.swift` — diff keyed by composite key.
- `VercelBar/Models/StateTransition.swift` — `StateTransition`/`DeploymentSnapshot` carry a `ProjectKey`.
- `VercelBar/Services/NotificationManager.swift` — gate by follow state via `ProjectKey`.
- `VercelBar/Views/PopoverView.swift` — grouped filter dropdown + source badges.
- `VercelBar/Views/SettingsView.swift` — Accounts tab + Projects (follow) tab; remove per-project toggles from Notifications.
- `VercelBar/VercelBarApp.swift` — wire `AccountStore` into `DeploymentStore`.

**New test files:**
- `VercelBarTests/AccountModelTests.swift`
- `VercelBarTests/CredentialStoreTests.swift`
- `VercelBarTests/AccountStoreTests.swift`
- `VercelBarTests/FollowSettingsTests.swift`
- `VercelBarTests/FollowMigrationTests.swift`
- `VercelBarTests/AggregationTests.swift` (extends DeploymentStore coverage)

---

## Task 1: `Provider` enum

**Files:**
- Create: `VercelBar/Models/Provider.swift`
- Test: `VercelBarTests/AccountModelTests.swift`

**Interfaces:**
- Produces: `enum Provider: String, Codable, CaseIterable, Sendable { case vercel, github, azureDevOps }` with `var displayName: String`, `var iconName: String`, `var isImplemented: Bool` (only `.vercel` is `true`).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import VercelBar

final class AccountModelTests: XCTestCase {
    func test_provider_onlyVercelImplemented() {
        XCTAssertTrue(Provider.vercel.isImplemented)
        XCTAssertFalse(Provider.github.isImplemented)
        XCTAssertFalse(Provider.azureDevOps.isImplemented)
    }

    func test_provider_displayNames() {
        XCTAssertEqual(Provider.vercel.displayName, "Vercel")
        XCTAssertEqual(Provider.github.displayName, "GitHub")
        XCTAssertEqual(Provider.azureDevOps.displayName, "Azure DevOps")
    }

    func test_provider_codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Provider.vercel)
        XCTAssertEqual(try JSONDecoder().decode(Provider.self, from: data), .vercel)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' -only-testing:VercelBarTests/AccountModelTests test`
Expected: FAIL — `cannot find 'Provider' in scope` (file doesn't exist yet). Run `xcodegen generate` first if the test file isn't in the project.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum Provider: String, Codable, CaseIterable, Sendable {
    case vercel
    case github
    case azureDevOps

    var displayName: String {
        switch self {
        case .vercel:      return "Vercel"
        case .github:      return "GitHub"
        case .azureDevOps: return "Azure DevOps"
        }
    }

    /// SF Symbol used in the dropdown/badges. (No brand symbols ship with SF; use neutral glyphs.)
    var iconName: String {
        switch self {
        case .vercel:      return "triangle.fill"
        case .github:      return "chevron.left.forwardslash.chevron.right"
        case .azureDevOps: return "cloud.fill"
        }
    }

    /// Whether a working client exists. Only Vercel ships in this milestone.
    var isImplemented: Bool { self == .vercel }
}
```

- [ ] **Step 4: Regenerate project and run test to verify it passes**

Run: `xcodegen generate && xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' -only-testing:VercelBarTests/AccountModelTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Models/Provider.swift VercelBarTests/AccountModelTests.swift VercelBar.xcodeproj
git commit -m "feat: add Provider enum"
```

---

## Task 2: `Account` and `CredentialSource`

**Files:**
- Create: `VercelBar/Models/Account.swift`
- Test: `VercelBarTests/AccountModelTests.swift` (append)

**Interfaces:**
- Consumes: `Provider` (Task 1).
- Produces:
  ```swift
  enum CredentialSource: Codable, Equatable, Sendable {
      case vercelCLI                 // token read from CLI config on disk
      case keychain(account: String) // token stored under this Keychain account name
  }
  struct Account: Codable, Identifiable, Equatable, Sendable {
      let id: UUID
      let provider: Provider
      var label: String              // display name (username/email/slug)
      let source: CredentialSource
  }
  ```
  Plus `static func vercelCLI(id:label:) -> Account` and `var isReadOnly: Bool` (true for `.vercelCLI`).

- [ ] **Step 1: Write the failing test (append to AccountModelTests.swift)**

```swift
extension AccountModelTests {
    func test_account_codableRoundTrip() throws {
        let acct = Account(id: UUID(), provider: .vercel, label: "alice",
                           source: .keychain(account: "kc-1"))
        let data = try JSONEncoder().encode(acct)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: data), acct)
    }

    func test_account_cliIsReadOnly() {
        let cli = Account.vercelCLI(id: UUID(), label: "from CLI")
        XCTAssertTrue(cli.isReadOnly)
        XCTAssertEqual(cli.source, .vercelCLI)
        XCTAssertEqual(cli.provider, .vercel)
    }

    func test_account_keychainNotReadOnly() {
        let acct = Account(id: UUID(), provider: .vercel, label: "bob",
                           source: .keychain(account: "kc-2"))
        XCTAssertFalse(acct.isReadOnly)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild … -only-testing:VercelBarTests/AccountModelTests test`
Expected: FAIL — `cannot find 'Account' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum CredentialSource: Codable, Equatable, Sendable {
    case vercelCLI
    case keychain(account: String)
}

struct Account: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let provider: Provider
    var label: String
    let source: CredentialSource

    var isReadOnly: Bool { source == .vercelCLI }

    static func vercelCLI(id: UUID, label: String) -> Account {
        Account(id: id, provider: .vercel, label: label, source: .vercelCLI)
    }
}
```

- [ ] **Step 4: Regenerate + run test**

Run: `xcodegen generate && xcodebuild … -only-testing:VercelBarTests/AccountModelTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Models/Account.swift VercelBarTests/AccountModelTests.swift VercelBar.xcodeproj
git commit -m "feat: add Account and CredentialSource models"
```

---

## Task 3: `ProjectKey` composite identity

**Files:**
- Create: `VercelBar/Models/ProjectFollow.swift`
- Test: `VercelBarTests/AccountModelTests.swift` (append)

**Interfaces:**
- Consumes: `Provider` (Task 1).
- Produces:
  ```swift
  struct ProjectKey: Hashable, Codable, Sendable {
      let provider: Provider
      let accountId: UUID
      let projectId: String
      var storageString: String     // stable string for UserDefaults set membership
      init(provider: Provider, accountId: UUID, projectId: String)
      init?(storageString: String)  // parse back
  }
  ```

- [ ] **Step 1: Write the failing test (append)**

```swift
extension AccountModelTests {
    func test_projectKey_storageRoundTrip() {
        let id = UUID()
        let key = ProjectKey(provider: .vercel, accountId: id, projectId: "prj_abc")
        let parsed = ProjectKey(storageString: key.storageString)
        XCTAssertEqual(parsed, key)
    }

    func test_projectKey_distinguishesAccounts() {
        let a = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "same")
        let b = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "same")
        XCTAssertNotEqual(a, b)               // same project name, different account → different key
        XCTAssertNotEqual(a.storageString, b.storageString)
    }

    func test_projectKey_rejectsMalformedString() {
        XCTAssertNil(ProjectKey(storageString: "garbage"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild … -only-testing:VercelBarTests/AccountModelTests test`
Expected: FAIL — `cannot find 'ProjectKey' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct ProjectKey: Hashable, Codable, Sendable {
    let provider: Provider
    let accountId: UUID
    let projectId: String

    init(provider: Provider, accountId: UUID, projectId: String) {
        self.provider = provider
        self.accountId = accountId
        self.projectId = projectId
    }

    /// Format: "<provider>|<accountUUID>|<projectId>". projectId is last so it
    /// may itself contain no "|" assumption-breaking — Vercel project ids don't.
    var storageString: String {
        "\(provider.rawValue)|\(accountId.uuidString)|\(projectId)"
    }

    init?(storageString: String) {
        let parts = storageString.split(separator: "|", maxSplits: 2,
                                        omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let provider = Provider(rawValue: parts[0]),
              let accountId = UUID(uuidString: parts[1]),
              !parts[2].isEmpty
        else { return nil }
        self.init(provider: provider, accountId: accountId, projectId: parts[2])
    }
}
```

- [ ] **Step 4: Regenerate + run test**

Run: `xcodegen generate && xcodebuild … -only-testing:VercelBarTests/AccountModelTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Models/ProjectFollow.swift VercelBarTests/AccountModelTests.swift VercelBar.xcodeproj
git commit -m "feat: add ProjectKey composite identity"
```

---

## Task 4: `CredentialStore` protocol + Keychain + in-memory fake

**Files:**
- Create: `VercelBar/Services/CredentialStore.swift`
- Test: `VercelBarTests/CredentialStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  protocol CredentialStore { 
      func token(for account: String) -> String?
      func setToken(_ token: String, for account: String)
      func removeToken(for account: String)
  }
  final class InMemoryCredentialStore: CredentialStore { init() }
  struct KeychainCredentialStore: CredentialStore { init(service: String = "io.eightlines.vercelbar") }
  ```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import VercelBar

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
        let store = KeychainCredentialStore(service: "io.eightlines.vercelbar.test.\(UUID().uuidString)")
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild … -only-testing:VercelBarTests/CredentialStoreTests test`
Expected: FAIL — `cannot find 'InMemoryCredentialStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Security

protocol CredentialStore {
    func token(for account: String) -> String?
    func setToken(_ token: String, for account: String)
    func removeToken(for account: String)
}

final class InMemoryCredentialStore: CredentialStore {
    private var storage: [String: String] = [:]
    func token(for account: String) -> String? { storage[account] }
    func setToken(_ token: String, for account: String) { storage[account] = token }
    func removeToken(for account: String) { storage[account] = nil }
}

/// Generic-password Keychain storage. macOS 14 compatible (uses the C Security API).
struct KeychainCredentialStore: CredentialStore {
    let service: String
    init(service: String = "io.eightlines.vercelbar") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func token(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    func setToken(_ token: String, for account: String) {
        let data = Data(token.utf8)
        // Try update first; insert if missing.
        let updated = SecItemUpdate(baseQuery(account) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func removeToken(for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
```

- [ ] **Step 4: Regenerate + run test**

Run: `xcodegen generate && xcodebuild … -only-testing:VercelBarTests/CredentialStoreTests test`
Expected: PASS (Keychain test requires the test host to have Keychain access; runs fine under the unit-test bundle on a local Mac).

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Services/CredentialStore.swift VercelBarTests/CredentialStoreTests.swift VercelBar.xcodeproj
git commit -m "feat: add CredentialStore (Keychain + in-memory)"
```

---

## Task 5: `Scope` and `ScopeFilter`

**Files:**
- Create: `VercelBar/Models/Scope.swift`
- Test: `VercelBarTests/AccountModelTests.swift` (append)

**Interfaces:**
- Consumes: `Account` (Task 2), `Team` (existing).
- Produces:
  ```swift
  struct Scope: Identifiable, Equatable, Sendable {
      let account: Account
      let teamId: String?       // nil = personal
      let teamName: String?     // display name; nil = "personal"
      var id: String            // "<account.id>|<teamId ?? "personal">"
      var displayName: String   // teamName ?? "personal"
  }
  enum ScopeFilter: Equatable {
      case all
      case provider(Provider)
      case account(UUID)
      case scope(accountId: UUID, teamId: String?)
      func matches(account: Account, teamId: String?) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing test (append to AccountModelTests.swift)**

```swift
extension AccountModelTests {
    func test_scope_id_personalVsTeam() {
        let acct = Account.vercelCLI(id: UUID(), label: "cli")
        let personal = Scope(account: acct, teamId: nil, teamName: nil)
        let team = Scope(account: acct, teamId: "team_1", teamName: "acme")
        XCTAssertTrue(personal.id.hasSuffix("personal"))
        XCTAssertTrue(team.id.hasSuffix("team_1"))
        XCTAssertEqual(personal.displayName, "personal")
        XCTAssertEqual(team.displayName, "acme")
    }

    func test_scopeFilter_matching() {
        let id = UUID()
        let acct = Account(id: id, provider: .vercel, label: "x", source: .keychain(account: "k"))
        XCTAssertTrue(ScopeFilter.all.matches(account: acct, teamId: "t"))
        XCTAssertTrue(ScopeFilter.provider(.vercel).matches(account: acct, teamId: nil))
        XCTAssertFalse(ScopeFilter.provider(.github).matches(account: acct, teamId: nil))
        XCTAssertTrue(ScopeFilter.account(id).matches(account: acct, teamId: "t"))
        XCTAssertFalse(ScopeFilter.account(UUID()).matches(account: acct, teamId: "t"))
        XCTAssertTrue(ScopeFilter.scope(accountId: id, teamId: "t").matches(account: acct, teamId: "t"))
        XCTAssertFalse(ScopeFilter.scope(accountId: id, teamId: "t").matches(account: acct, teamId: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild … -only-testing:VercelBarTests/AccountModelTests test`
Expected: FAIL — `cannot find 'Scope' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct Scope: Identifiable, Equatable, Sendable {
    let account: Account
    let teamId: String?
    let teamName: String?

    var id: String { "\(account.id.uuidString)|\(teamId ?? "personal")" }
    var displayName: String { teamName ?? "personal" }
}

enum ScopeFilter: Equatable {
    case all
    case provider(Provider)
    case account(UUID)
    case scope(accountId: UUID, teamId: String?)

    func matches(account: Account, teamId: String?) -> Bool {
        switch self {
        case .all:                       return true
        case .provider(let p):           return account.provider == p
        case .account(let id):           return account.id == id
        case .scope(let id, let team):   return account.id == id && team == teamId
        }
    }
}
```

- [ ] **Step 4: Regenerate + run test**

Run: `xcodegen generate && xcodebuild … -only-testing:VercelBarTests/AccountModelTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Models/Scope.swift VercelBarTests/AccountModelTests.swift VercelBar.xcodeproj
git commit -m "feat: add Scope and ScopeFilter"
```

---

## Task 6: `SourcedDeployment` / `SourcedProject`

**Files:**
- Create: `VercelBar/Models/SourcedItem.swift`
- Test: `VercelBarTests/AccountModelTests.swift` (append)

**Interfaces:**
- Consumes: `Account` (Task 2), `Deployment`/`Project` (existing), `ProjectKey` (Task 3).
- Produces:
  ```swift
  struct SourcedDeployment: Identifiable {
      let deployment: Deployment
      let account: Account
      var id: String                 // "<account.id>|<deployment.uid>"
  }
  struct SourcedProject: Identifiable {
      let project: Project
      let account: Account
      var id: String                 // "<account.id>|<project.id>"
      var key: ProjectKey            // ProjectKey(provider:account.provider, accountId:account.id, projectId:project.id)
  }
  ```

- [ ] **Step 1: Write the failing test (append)**

```swift
extension AccountModelTests {
    func test_sourcedProject_keyAndId() throws {
        let acct = Account.vercelCLI(id: UUID(), label: "cli")
        let json = #"{"id":"prj_1","name":"web","productionAliases":[],"envCount":0,"cronCount":0,"hasAnalytics":false}"#
        // Build a Project via its real decoder path used elsewhere in tests:
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        let sp = SourcedProject(project: project, account: acct)
        XCTAssertEqual(sp.id, "\(acct.id.uuidString)|prj_1")
        XCTAssertEqual(sp.key, ProjectKey(provider: .vercel, accountId: acct.id, projectId: "prj_1"))
    }
}
```

> NOTE FOR IMPLEMENTER: `Project`'s decoder expects nested Vercel JSON. If the
> inline JSON above does not decode cleanly against the real `Project` decoder,
> copy a minimal valid project object from an existing fixture in
> `VercelBarTests/Fixtures/` (see `ProjectDecodingTests.swift` for the shape)
> rather than inventing fields. The assertion targets `id`/`key` only.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild … -only-testing:VercelBarTests/AccountModelTests test`
Expected: FAIL — `cannot find 'SourcedProject' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct SourcedDeployment: Identifiable {
    let deployment: Deployment
    let account: Account
    var id: String { "\(account.id.uuidString)|\(deployment.uid)" }
}

struct SourcedProject: Identifiable {
    let project: Project
    let account: Account
    var id: String { "\(account.id.uuidString)|\(project.id)" }
    var key: ProjectKey {
        ProjectKey(provider: account.provider, accountId: account.id, projectId: project.id)
    }
}
```

- [ ] **Step 4: Regenerate + run test**

Run: `xcodegen generate && xcodebuild … -only-testing:VercelBarTests/AccountModelTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Models/SourcedItem.swift VercelBarTests/AccountModelTests.swift VercelBar.xcodeproj
git commit -m "feat: add SourcedDeployment/SourcedProject"
```

---

## Task 7: `DeploymentProviderClient` protocol + `VercelClient` conformance

**Files:**
- Create: `VercelBar/Clients/DeploymentProviderClient.swift`
- Modify: none to `VercelClient.swift` (conformance lives in the new file as an extension)
- Test: `VercelBarTests/VercelClientTests.swift` (append a conformance test)

**Interfaces:**
- Consumes: `Scope` (Task 5), `VercelClient`/`TeamsClient`/`UserClient` (existing).
- Produces:
  ```swift
  protocol DeploymentProviderClient: Sendable {
      func deployments(limit: Int) async throws -> [Deployment]
      func projects() async throws -> [Project]
  }
  extension VercelClient: DeploymentProviderClient {}   // already has matching methods
  ```

> Rationale: `VercelClient.deployments(limit:)` and `projects()` already match the
> protocol exactly, so conformance is empty. Teams/user remain on their own clients
> (`TeamsClient`/`UserClient`) and are not part of this protocol — they're account-level,
> not scope-level, and the aggregator calls them separately.

- [ ] **Step 1: Write the failing test (append to VercelClientTests.swift)**

```swift
extension VercelClientTests {
    func test_vercelClient_conformsToProviderProtocol() async throws {
        let client: DeploymentProviderClient = VercelClient(
            credentials: VercelCredentials(token: "x", teamId: nil)
        ) { req in
            let isDeployments = req.url!.path.contains("deployments")
            let body = isDeployments ? #"{"deployments":[]}"# : #"{"projects":[]}"#
            return (Data(body.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let deps = try await client.deployments(limit: 5)
        let projs = try await client.projects()
        XCTAssertTrue(deps.isEmpty)
        XCTAssertTrue(projs.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild … -only-testing:VercelBarTests/VercelClientTests test`
Expected: FAIL — `cannot find type 'DeploymentProviderClient' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The per-scope data surface every provider must offer. Teams/user are account-level
/// and handled separately by the aggregator.
protocol DeploymentProviderClient: Sendable {
    func deployments(limit: Int) async throws -> [Deployment]
    func projects() async throws -> [Project]
}

extension VercelClient: DeploymentProviderClient {}
```

> If the compiler complains that `VercelClient` is not `Sendable`, add `: Sendable`
> conformance to `VercelClient`'s declaration (it holds only a `let` struct + a
> `@Sendable`-compatible closure; mark the `fetch` typealias `@Sendable` if needed).
> Under `SWIFT_STRICT_CONCURRENCY: minimal` this is usually not required — only add it
> if the build fails.

- [ ] **Step 4: Regenerate + run test**

Run: `xcodegen generate && xcodebuild … -only-testing:VercelBarTests/VercelClientTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Clients/DeploymentProviderClient.swift VercelBarTests/VercelClientTests.swift VercelBar.xcodeproj
git commit -m "feat: add DeploymentProviderClient protocol; VercelClient conforms"
```

---

## Task 8: `SettingsStore` follow API + migration

**Files:**
- Modify: `VercelBar/Stores/SettingsStore.swift`
- Test: `VercelBarTests/FollowSettingsTests.swift`, `VercelBarTests/FollowMigrationTests.swift`

**Interfaces:**
- Consumes: `ProjectKey` (Task 3).
- Produces (new public API on `SettingsStore`):
  ```swift
  var autoFollowNewProjects: Bool { get set }     // default true
  func isFollowed(_ key: ProjectKey) -> Bool       // unknown key → autoFollowNewProjects
  func setFollowed(_ key: ProjectKey, _ followed: Bool)
  func migrateLegacyFollowData(cliAccountId: UUID) // disabledProjects → unfollowed keys; runs once
  ```
- Keeps: `selectedTeamId` getter for migration reads (don't delete the key yet).

> Model: an explicit set of *unfollowed* keys plus an `autoFollowNewProjects` flag.
> A key is followed iff it's not in the unfollowed set (when auto-follow is on) — i.e.
> opt-out, matching today's behavior. When auto-follow is OFF, only an explicit
> *followed* set counts. To keep this simple and matched to the spec ("default follow
> all new"), store two sets: `followedKeys` and `unfollowedKeys`, and resolve:
> followed = explicit-followed OR (autoFollow AND not explicit-unfollowed).

- [ ] **Step 1: Write the failing tests**

`FollowSettingsTests.swift`:
```swift
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
```

`FollowMigrationTests.swift`:
```swift
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
```

> IMPLEMENTER NOTE — legacy keying mismatch: the old `disabledProjects` stored project
> **names**; the new `ProjectKey` uses project **ids**. Vercel project name and id differ.
> For migration we store the legacy *names* as unfollowed keys using the name in the
> `projectId` slot. Then in Task 10, when resolving follow state for a real project,
> the store ALSO checks a name-based legacy key as a fallback for the CLI account so
> pre-existing mutes survive until the user toggles them. Implement that fallback in
> Task 10; here only store + clear + once-guard.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild … -only-testing:VercelBarTests/FollowSettingsTests -only-testing:VercelBarTests/FollowMigrationTests test`
Expected: FAIL — `value of type 'SettingsStore' has no member 'autoFollowNewProjects'`.

- [ ] **Step 3: Implement**

Add to `SettingsStore` (and add the new keys to the `Keys` enum):
```swift
// in Keys:
static let followedKeys      = "followedProjectKeys"
static let unfollowedKeys    = "unfollowedProjectKeys"
static let autoFollowNew     = "autoFollowNewProjects"
static let didMigrateFollow  = "didMigrateFollowData"
```
```swift
// in init's register defaults, add:
Keys.autoFollowNew: true,
```
```swift
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
```
Remove the old `isProjectEnabled`/`setProject` methods **only after Task 9 and Task 11 stop calling them** — to keep this task compiling, leave them in place for now (Task 11 deletes them).

- [ ] **Step 4: Regenerate + run tests**

Run: `xcodegen generate && xcodebuild … -only-testing:VercelBarTests/FollowSettingsTests -only-testing:VercelBarTests/FollowMigrationTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Stores/SettingsStore.swift VercelBarTests/FollowSettingsTests.swift VercelBarTests/FollowMigrationTests.swift VercelBar.xcodeproj
git commit -m "feat: SettingsStore follow API + legacy migration"
```

---

## Task 9: `AccountStore`

**Files:**
- Create: `VercelBar/Stores/AccountStore.swift`
- Test: `VercelBarTests/AccountStoreTests.swift`

**Interfaces:**
- Consumes: `Account`/`CredentialSource` (Task 2), `CredentialStore` (Task 4), `Provider` (Task 1), `TokenProvider`/`VercelCredentials` (existing).
- Produces:
  ```swift
  @Observable @MainActor final class AccountStore {
      private(set) var accounts: [Account]
      init(defaults: UserDefaults = .standard,
           credentials: CredentialStore = KeychainCredentialStore(),
           detectCLI: () -> Bool = { (try? TokenProvider().credentials()) != nil })
      func token(for account: Account) -> String?       // CLI → disk; keychain → store
      @discardableResult func addKeychainAccount(provider: Provider, label: String, token: String) -> Account
      func removeAccount(_ account: Account)             // also deletes keychain secret
      var cliAccount: Account? { get }                   // the detected Vercel CLI account, if present
  }
  ```

> Behavior: on init, if `detectCLI()` is true and no CLI account is persisted, create one
> (stable UUID persisted so `ProjectKey`s remain stable across launches). Persist the
> non-secret `[Account]` array (Codable) in UserDefaults; secrets only in `CredentialStore`.
> `token(for:)` returns the CLI token by reading `TokenProvider().credentials().token`
> for `.vercelCLI`, and `credentials.token(for: kcName)` for `.keychain`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import VercelBar

@MainActor
final class AccountStoreTests: XCTestCase {
    private func fresh(detectCLI: Bool = false) -> (AccountStore, InMemoryCredentialStore, UserDefaults) {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let creds = InMemoryCredentialStore()
        let store = AccountStore(defaults: d, credentials: creds, detectCLI: { detectCLI })
        return (store, creds, d)
    }

    func test_noCLI_startsEmpty() {
        let (store, _, _) = fresh(detectCLI: false)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.cliAccount)
    }

    func test_cliDetected_createsReadOnlyAccount() {
        let (store, _, _) = fresh(detectCLI: true)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.cliAccount?.source, .vercelCLI)
        XCTAssertTrue(store.cliAccount!.isReadOnly)
    }

    func test_cliAccount_idStableAcrossInstances() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let s1 = AccountStore(defaults: d, credentials: InMemoryCredentialStore(), detectCLI: { true })
        let firstId = s1.cliAccount!.id
        let s2 = AccountStore(defaults: d, credentials: InMemoryCredentialStore(), detectCLI: { true })
        XCTAssertEqual(s2.cliAccount!.id, firstId)
    }

    func test_addKeychainAccount_storesTokenAndPersists() {
        let (store, creds, d) = fresh()
        let acct = store.addKeychainAccount(provider: .vercel, label: "bob", token: "tok-9")
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.token(for: acct), "tok-9")
        // Persisted across a reload:
        let reloaded = AccountStore(defaults: d, credentials: creds, detectCLI: { false })
        XCTAssertEqual(reloaded.accounts.count, 1)
        XCTAssertEqual(reloaded.token(for: reloaded.accounts[0]), "tok-9")
    }

    func test_removeAccount_deletesSecret() {
        let (store, creds, _) = fresh()
        let acct = store.addKeychainAccount(provider: .vercel, label: "bob", token: "tok-9")
        store.removeAccount(acct)
        XCTAssertTrue(store.accounts.isEmpty)
        if case .keychain(let name) = acct.source { XCTAssertNil(creds.token(for: name)) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild … -only-testing:VercelBarTests/AccountStoreTests test`
Expected: FAIL — `cannot find 'AccountStore' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

@Observable
@MainActor
final class AccountStore {
    private(set) var accounts: [Account] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let reloadCLIToken: () -> String?

    private enum Keys { static let accounts = "connectedAccounts" }

    init(defaults: UserDefaults = .standard,
         credentials: CredentialStore = KeychainCredentialStore(),
         detectCLI: () -> Bool = { (try? TokenProvider().credentials()) != nil },
         reloadCLIToken: @escaping () -> String? = { try? TokenProvider().credentials().token }) {
        self.defaults = defaults
        self.credentials = credentials
        self.reloadCLIToken = reloadCLIToken
        self.accounts = Self.load(defaults)

        if detectCLI(), cliAccount == nil {
            let cli = Account.vercelCLI(id: UUID(), label: "Vercel CLI")
            accounts.insert(cli, at: 0)
            persist()
        }
    }

    var cliAccount: Account? { accounts.first { $0.source == .vercelCLI } }

    func token(for account: Account) -> String? {
        switch account.source {
        case .vercelCLI:            return reloadCLIToken()
        case .keychain(let name):   return credentials.token(for: name)
        }
    }

    @discardableResult
    func addKeychainAccount(provider: Provider, label: String, token: String) -> Account {
        let kcName = "acct-\(UUID().uuidString)"
        credentials.setToken(token, for: kcName)
        let acct = Account(id: UUID(), provider: provider, label: label,
                           source: .keychain(account: kcName))
        accounts.append(acct)
        persist()
        return acct
    }

    func removeAccount(_ account: Account) {
        if case .keychain(let name) = account.source { credentials.removeToken(for: name) }
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Keys.accounts)
    }

    private static func load(_ defaults: UserDefaults) -> [Account] {
        guard let data = defaults.data(forKey: Keys.accounts),
              let decoded = try? JSONDecoder().decode([Account].self, from: data)
        else { return [] }
        return decoded
    }
}
```

- [ ] **Step 4: Regenerate + run test**

Run: `xcodegen generate && xcodebuild … -only-testing:VercelBarTests/AccountStoreTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Stores/AccountStore.swift VercelBarTests/AccountStoreTests.swift VercelBar.xcodeproj
git commit -m "feat: add AccountStore"
```

---

## Task 10: `DeploymentStore` multi-scope aggregator

**Files:**
- Modify: `VercelBar/Stores/DeploymentStore.swift`
- Modify: `VercelBar/Models/StateTransition.swift` (add `key: ProjectKey` to `StateTransition`/`DeploymentSnapshot`)
- Modify: `VercelBar/Stores/DeploymentDiffer.swift` (diff keyed by uid still, but carry the key through)
- Modify: `VercelBar/Services/NotificationManager.swift` (gate by `isFollowed(key)`)
- Test: `VercelBarTests/AggregationTests.swift`; adapt `VercelBarTests/DeploymentStoreTests.swift` if its constructor changes.

**Interfaces:**
- Consumes: `AccountStore` (Task 9), `Scope`/`ScopeFilter` (Task 5), `SourcedDeployment`/`SourcedProject` (Task 6), `SettingsStore` follow API (Task 8), `DeploymentProviderClient` (Task 7).
- Produces (new shape on `DeploymentStore`):
  ```swift
  var sourcedDeployments: [SourcedDeployment]   // followed + filtered, newest first
  var sourcedProjects: [SourcedProject]         // followed + filtered
  var filter: ScopeFilter                        // default .all
  var availableScopes: [Scope]                   // every connected account × its teams (+ personal)
  var sourceErrors: [UUID: String]               // accountId → last error message
  var connectedSourceCount: Int                  // accounts contributing rows (for badge gating)
  func setFilter(_ filter: ScopeFilter)
  ```
- Keep `iconState`/`IconState` (now aggregated across `sourcedDeployments`).

> This is the largest task. Strategy:
> 1. Build a per-scope client factory: `makeClient(account:teamId:) -> DeploymentProviderClient?`
>    that fetches the token via `AccountStore.token(for:)` and builds a `VercelClient` for
>    `.vercel` accounts; returns `nil` for unimplemented providers (skipped).
> 2. `poll()` enumerates `availableScopes`, fans out fetches via `withTaskGroup`, tags each
>    result with its `Account` (`SourcedDeployment`/`SourcedProject`), records per-source
>    errors without clearing other sources, then merges + applies the follow filter
>    (`settings.isFollowed(sp.key)`, with the legacy name fallback for the CLI account) and
>    the active `ScopeFilter`.
> 3. Notifications diff per uid as today but carry `ProjectKey`; the gate checks
>    `isFollowed(key)` instead of `isProjectEnabled(name)`.
> 4. Auth/token-rotation retry stays per Vercel-CLI scope (reuse existing logic, scoped to
>    that one fetch). A keychain account that 401s repeatedly sets a "needs re-auth" error
>    for that account id; it does not flip the whole app to logged-out.
> 5. `iconState`: `.loggedOut` only when there are zero usable sources (no accounts, or all
>    failing auth); otherwise aggregate failure>building>ready across followed deployments.

Because this is large, split into sub-steps with their own red/green cycles.

- [ ] **Step 1: Extend `StateTransition`/`DeploymentSnapshot` with `key` (failing test)**

Add to a new `AggregationTests.swift`:
```swift
import XCTest
@testable import VercelBar

@MainActor
final class AggregationTests: XCTestCase {
    func test_snapshotCarriesProjectKey() {
        let key = ProjectKey(provider: .vercel, accountId: UUID(), projectId: "p")
        let snap = DeploymentSnapshot(uid: "u1", name: "web", state: .building, key: key)
        XCTAssertEqual(snap.key, key)
    }
}
```

- [ ] **Step 2: Run → fails** (`extra argument 'key'`). Run only `AggregationTests`.

- [ ] **Step 3: Implement the model change**

In `StateTransition.swift`:
```swift
struct StateTransition: Equatable {
    let uid: String
    let project: String
    let key: ProjectKey
    let event: DeploymentEvent
}

struct DeploymentSnapshot: Equatable {
    let uid: String
    let name: String
    let state: DeploymentState
    let key: ProjectKey
}

extension DeploymentSnapshot {
    init(_ d: Deployment, key: ProjectKey) {
        self.init(uid: d.uid, name: d.name, state: d.state, key: key)
    }
}
```
Update `DeploymentDiffer.transitions` to thread `dep.key` into each `StateTransition`:
```swift
result.append(StateTransition(uid: dep.uid, project: dep.name, key: dep.key, event: event))
```
Update `NotificationManager`/`NotificationGate`:
```swift
enum NotificationGate {
    static func shouldNotify(_ t: StateTransition, settings: SettingsStore) -> Bool {
        guard settings.isFollowed(t.key) else { return false }
        switch t.event {
        case .failure:  return settings.notifyOnFailure
        case .success:  return settings.notifyOnSuccess
        case .started:  return settings.notifyOnStarted
        case .canceled: return settings.notifyOnCanceled
        }
    }
}
```

- [ ] **Step 4: Run `AggregationTests` step-1 test → passes.** Also run `DiffTests` and `NotificationGatingTests`; **adapt them** to the new `key` field (construct a `ProjectKey` in each fixture). Show the exact edits in those files (add `let key = ProjectKey(provider:.vercel, accountId: UUID(), projectId: "x")` and pass it).

- [ ] **Step 5: Commit the model/diff/notification change**

```bash
git add VercelBar/Models/StateTransition.swift VercelBar/Stores/DeploymentDiffer.swift VercelBar/Services/NotificationManager.swift VercelBarTests/AggregationTests.swift VercelBarTests/DiffTests.swift VercelBarTests/NotificationGatingTests.swift VercelBar.xcodeproj
git commit -m "feat: thread ProjectKey through diffing and notifications"
```

- [ ] **Step 6: Aggregation merge+filter test (failing)**

Append to `AggregationTests.swift` — a store built with a fake `AccountStore` (two keychain accounts) and a stub client factory returning canned deployments/projects per account. Assert:
- `sourcedProjects` merges both accounts.
- An unfollowed project (via `settings.setFollowed(key,false)`) is excluded.
- A `ScopeFilter.account(id)` narrows to one account.
- One account's fetch throwing records `sourceErrors[id]` but the other account's rows still appear.

```swift
extension AggregationTests {
    func test_aggregatesAndFiltersAcrossAccounts() async {
        // Implementer: construct DeploymentStore with injected accountStore + a
        // makeClient closure that returns a stub DeploymentProviderClient per account.
        // Use two InMemory-backed accounts. Follow defaults to all.
        // 1) poll → sourcedProjects contains projects from both accounts
        // 2) setFollowed(projectKeyForAccountA, false) → that project drops out
        // 3) setFilter(.account(accountB.id)) → only account B rows remain
        // 4) make account A's client throw → sourceErrors[accountA.id] != nil,
        //    account B rows still present
    }
}
```

> IMPLEMENTER: the `DeploymentStore` init must gain injection points:
> `accountStore: AccountStore`, and
> `makeClient: (Account, _ teamId: String?) -> DeploymentProviderClient?`
> defaulting to the real Vercel factory. Keep the existing test seams
> (`reloadToken`, `authRetryBackoff`) where they still make sense (CLI scope only).

- [ ] **Step 7: Run → fails.** Expected: members `sourcedProjects`/`setFilter` not found.

- [ ] **Step 8: Implement the aggregator.** Rewrite `DeploymentStore` per the strategy above. Key points to preserve from the current implementation:
  - `iconState(for:)` pure helper (keep; reuse for aggregate).
  - Per-CLI-scope token rotation + single-retry (`refreshTokenIfChanged` logic) — scope it to the CLI account's fetch.
  - `previousSnapshots` baseline for silent first poll — now a dictionary keyed by `ProjectKey`'s account so switching filters does not re-notify; simplest correct approach: keep ONE snapshot list across all sources keyed by `uid`, seeded on first successful aggregate poll.
  - `scheduleTimer()` unchanged.
  - Replace `deployments`/`projects` arrays with `sourcedDeployments`/`sourcedProjects`; keep `errorMessage` derived from `sourceErrors` (none → nil; one → its message; many → "N accounts couldn't refresh").

- [ ] **Step 9: Run `AggregationTests` → passes.** Then run the **full** suite and fix fallout (the old `DeploymentStoreTests` referenced `store.deployments`; update those references to `store.sourcedDeployments.map(\.deployment)` or adapt assertions). Show each edit.

Run: `xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' test`
Expected: PASS (all classes).

- [ ] **Step 10: Commit**

```bash
git add VercelBar/Stores/DeploymentStore.swift VercelBarTests VercelBar.xcodeproj
git commit -m "feat: DeploymentStore becomes multi-scope aggregator"
```

---

## Task 11: Wire `AccountStore` into app + run migration

**Files:**
- Modify: `VercelBar/VercelBarApp.swift`
- Modify: `VercelBar/Stores/SettingsStore.swift` (delete now-unused `isProjectEnabled`/`setProject` and the `disabledProjects` key usage — migration already reads it directly)
- Test: existing suite must stay green.

- [ ] **Step 1: Update `VercelBarApp.init`** to create `AccountStore` first, run `settings.migrateLegacyFollowData(cliAccountId:)` with the CLI account id (if any), then construct `DeploymentStore(accountStore:settings:…)`. Preserve the existing `selectedTeamId` → CLI default scope behavior by seeding the CLI account's default team into the store's initial filter (or leave filter `.all`, which already shows everything — acceptable; note this in the commit).

```swift
init() {
    let settings = SettingsStore()
    let accountStore = AccountStore()
    if let cli = accountStore.cliAccount {
        settings.migrateLegacyFollowData(cliAccountId: cli.id)
    }
    let store = DeploymentStore(accountStore: accountStore, settings: settings)
    _settings = State(initialValue: settings)
    _accountStore = State(initialValue: accountStore)
    _store = State(initialValue: store)
}
```
Add `@State private var accountStore: AccountStore` and pass it to `SettingsView`.

- [ ] **Step 2: Delete dead code in `SettingsStore`** — remove `isProjectEnabled`/`setProject`; the `disabledProjects` Keys entry stays only if `migrateLegacyFollowData` still references the string literal (it uses `Keys.disabledProjects`, so keep the constant).

- [ ] **Step 3: Build the app target** (not just tests) to catch wiring errors:

Run: `xcodegen generate && xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run full test suite**

Run: `xcodebuild … test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VercelBar/VercelBarApp.swift VercelBar/Stores/SettingsStore.swift VercelBar.xcodeproj
git commit -m "feat: wire AccountStore into app; run follow migration; remove dead opt-out API"
```

---

## Task 12: Popover — grouped filter dropdown + source badges

**Files:**
- Modify: `VercelBar/Views/PopoverView.swift`
- Create: `VercelBar/Views/SourceBadge.swift`

> UI task — no unit tests (SwiftUI views are verified by building + manual run, consistent
> with the existing test suite which does not test views). Each step builds and the final
> step is a manual smoke check.

- [ ] **Step 1: Replace `teamMenu` with a grouped filter `Menu`.** Top item `All` (checkmark when `store.filter == .all`). Then `ForEach(Provider.allCases)` as `Section(provider.displayName)`: for implemented providers list connected accounts (from `store`/`accountStore`) and, under each, its scopes (personal + teams) as buttons setting `store.setFilter(.scope(accountId:teamId:))`; for unimplemented providers show a single disabled `Text("\(name) — coming soon")`. Add a trailing `Divider()` + `Button("Manage accounts…") { openSettings() }`. Label shows the active filter's name.

```swift
// label resolution helper
private var filterLabel: String {
    switch store.filter {
    case .all: return "All"
    case .provider(let p): return p.displayName
    case .account(let id): return store.account(id)?.label ?? "Account"
    case .scope(let id, let team): return store.scopeName(accountId: id, teamId: team) ?? "Scope"
    }
}
```
(Implementer: add small read-only helpers `account(_:)`/`scopeName(accountId:teamId:)` on `DeploymentStore` backed by `availableScopes`.)

- [ ] **Step 2: Create `SourceBadge`** — a tiny capsule showing `Image(systemName: account.provider.iconName)` + (when more than one account connected) the account label, used in rows.

```swift
import SwiftUI

struct SourceBadge: View {
    let account: Account
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: account.provider.iconName).imageScale(.small)
            Text(account.label).lineLimit(1)
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 3: Update the lists** to iterate `store.sourcedDeployments` / `store.sourcedProjects`, passing the inner `deployment`/`project` to the existing rows and appending `SourceBadge(account:)` **only when `store.connectedSourceCount > 1`**.

- [ ] **Step 4: Build + manual smoke run**

Run: `xcodegen generate && xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' build`
Then run the app from Xcode (or `open` the built `.app`) and confirm: dropdown shows `All` + a `Vercel` section with the CLI account + teams, and a disabled GitHub "coming soon" entry; selecting a scope filters the lists; single-account case shows no badges.
Expected: builds and behaves as described.

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Views/PopoverView.swift VercelBar/Views/SourceBadge.swift VercelBar.xcodeproj
git commit -m "feat: grouped provider/account/team filter dropdown + source badges"
```

---

## Task 13: Settings — Accounts tab + Projects (follow) tab

**Files:**
- Modify: `VercelBar/Views/SettingsView.swift`

> UI task. The existing per-project toggles move OUT of Notifications into a new Projects tab,
> and the Account tab becomes Accounts (list + add/remove).

- [ ] **Step 1: Accounts tab.** Replace `AccountSettingsTab` with a list grouped by provider: for each `account` in `accountStore.accounts` show its label, source ("from Vercel CLI" when `isReadOnly`, else "Token"), and a Remove button (hidden/disabled when `isReadOnly`). Add an **"Add account"** control: a `Picker` for implemented providers + a `SecureField` for the token + an "Add" button calling `accountStore.addKeychainAccount(provider:label:token:)`. Keep the `vercel login` guidance footer. (Resolving a friendly label from the token via the API can come later; for now use a user-entered label field or default to the provider name.)

- [ ] **Step 2: Projects (follow) tab.** New `Label("Projects", systemImage: "square.stack.3d.up")`. A `Toggle("Automatically follow new projects", isOn:)` bound to `settings.autoFollowNewProjects`. Then, grouped by account, a `Toggle(project.name, isOn:)` per `store.sourcedProjects` bound to `settings.isFollowed(sp.key)` / `settings.setFollowed(sp.key, $0)`. Footer: "Unfollowed projects are hidden from the menu and never notify."

- [ ] **Step 3: Notifications tab** — delete the per-project `Section`; keep only the event toggles.

- [ ] **Step 4: `SettingsView` plumbing** — add `let accountStore: AccountStore` parameter (passed from `VercelBarApp`), wire the three tabs.

- [ ] **Step 5: Build + manual smoke run**

Run: `xcodegen generate && xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' build`
Then open Settings and confirm: Accounts lists the CLI account (read-only) and lets you add a token account; Projects tab toggles follow state and the popover list updates; Notifications no longer lists projects.
Expected: builds and behaves as described.

- [ ] **Step 6: Commit**

```bash
git add VercelBar/Views/SettingsView.swift VercelBar.xcodeproj
git commit -m "feat: Settings Accounts tab + Projects (follow) tab"
```

---

## Task 14: Full verification pass

- [ ] **Step 1: Regenerate + full test suite**

Run: `xcodegen generate && xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' test 2>&1 | xcbeautify`
Expected: all tests PASS.

- [ ] **Step 2: Manual end-to-end smoke (logged in via `vercel login`)**
  - Menu icon reflects aggregate state.
  - Dropdown: All / Vercel(account→teams) / GitHub "coming soon" disabled / "Manage accounts…".
  - Filtering narrows the lists; switching back to All restores them.
  - Settings → Projects: unfollow a project → it disappears from the popover and stops notifying; "auto-follow new" off → newly-seen projects don't appear until followed.
  - Settings → Accounts: add a (valid) Vercel token account → its projects appear with source badges alongside the CLI account's; remove it → its rows and Keychain secret are gone.
  - Pre-existing muted projects (from the old build) remain unfollowed after upgrade (migration).

- [ ] **Step 3: Commit any fixes, then final commit**

```bash
git add -A
git commit -m "test: full verification pass for multi-provider foundation"
```

---

## Self-Review notes (resolved)

- **Spec coverage:** Provider/Account/Scope/Followed (Tasks 1–6, 8); manual token entry + Keychain + CLI default (Tasks 4, 9, 13); aggregator with per-source isolation (Task 10); grouped filter dropdown + badges (Task 12); Accounts + Projects settings (Task 13); migration of `disabledProjects` (Task 8) and `selectedTeamId` handling (Task 11, noted as acceptable-default `.all`). All spec sections map to tasks.
- **Legacy keying caveat** (names vs ids) is called out explicitly in Task 8's implementer note and handled as a CLI-account fallback in Task 10 — the one genuine ambiguity in the spec, made explicit here.
- **Type consistency:** `ProjectKey.storageString`, `isFollowed`/`setFollowed`, `SourcedProject.key`, `ScopeFilter` cases, `sourcedDeployments`/`sourcedProjects` are used consistently across Tasks 8/10/12/13.
