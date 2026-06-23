# Pull-to-Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pulling the popover's deployments/projects list down with the trackpad triggers a manual refresh, with a loading spinner revealed by the pull.

**Architecture:** macOS has no native pull-to-refresh, so it's built manually. `DeploymentStore` gains an observable `isRefreshing` flag and a `manualRefresh()` method that wraps the existing `poll()`. `PopoverView`'s `ScrollView` is wrapped in a `RefreshableList` subview that tracks vertical content offset via `onScrollGeometryChange` (macOS 15+) and fires `manualRefresh()` when over-pulled past a threshold.

**Tech Stack:** SwiftUI (macOS 15+), `@Observable` store, XCTest.

## Global Constraints

- Minimum macOS deployment target: **15.0** (bumped from 14.0 in this plan — required for `onScrollGeometryChange`).
- Reuse the existing `poll()` re-entrancy guard (`isPollInFlight`); do not add a second guard.
- Do not change the existing timer-based polling cadence.
- Leave the unrelated uncommitted working-tree changes (token rotation in `DeploymentStore.swift`, `SettingsView.swift`, tests) untouched — only add to them.
- Build/test command: `xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' test`.

---

### Task 1: Add `isRefreshing` state and `manualRefresh()` to the store

**Files:**
- Modify: `VercelBar/Stores/DeploymentStore.swift` (add property near line 9–14; add method after `poll()` ~line 161)
- Test: `VercelBarTests/DeploymentStoreTests.swift`

**Interfaces:**
- Consumes: existing `func poll() async`, existing `makeStore(...)` test helper.
- Produces:
  - `var isRefreshing: Bool` — observable, `false` at rest, `true` only for the duration of a `manualRefresh()` call.
  - `func manualRefresh() async` — sets `isRefreshing = true`, awaits `poll()`, resets `isRefreshing = false` via `defer`.

- [ ] **Step 1: Write the failing test**

Add to `VercelBarTests/DeploymentStoreTests.swift` (after `test_firstPollPopulatesAndClearsError`):

```swift
func test_manualRefreshPopulatesAndResetsFlag() async throws {
    let store = makeStore(deploymentsData: try fixture("deployments"))
    XCTAssertFalse(store.isRefreshing)
    await store.manualRefresh()
    XCTAssertFalse(store.deployments.isEmpty)
    XCTAssertFalse(store.isRefreshing, "isRefreshing must reset after manualRefresh completes")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' test -only-testing:VercelBarTests/DeploymentStoreTests/test_manualRefreshPopulatesAndResetsFlag`
Expected: FAIL — compile error, `isRefreshing` / `manualRefresh` not found.

- [ ] **Step 3: Add the property**

In `VercelBar/Stores/DeploymentStore.swift`, add alongside the other observable vars (after `var lastUpdated: Date?` ~line 14):

```swift
    var isRefreshing = false
```

- [ ] **Step 4: Add the method**

In `VercelBar/Stores/DeploymentStore.swift`, add immediately after the closing brace of `func poll()` (~line 161):

```swift
    /// User-initiated refresh (pull-to-refresh). Reuses `poll()` — whose
    /// `isPollInFlight` guard makes overlapping triggers safe — and exposes an
    /// observable `isRefreshing` flag so the UI can show a spinner.
    func manualRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await poll()
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' test -only-testing:VercelBarTests/DeploymentStoreTests/test_manualRefreshPopulatesAndResetsFlag`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add VercelBar/Stores/DeploymentStore.swift VercelBarTests/DeploymentStoreTests.swift
git commit -m "feat: add manualRefresh and isRefreshing to DeploymentStore"
```

---

### Task 2: Bump macOS deployment target to 15.0

**Files:**
- Modify: `VercelBar.xcodeproj/project.pbxproj` (two `MACOSX_DEPLOYMENT_TARGET = 14.0;` lines, ~500 and ~563)

**Interfaces:**
- Consumes: nothing.
- Produces: project builds against the macOS 15 SDK, making `onScrollGeometryChange` available to Task 3.

- [ ] **Step 1: Change both deployment-target entries**

Replace every occurrence of `MACOSX_DEPLOYMENT_TARGET = 14.0;` with `MACOSX_DEPLOYMENT_TARGET = 15.0;` in `VercelBar.xcodeproj/project.pbxproj`. There are exactly two.

- [ ] **Step 2: Verify both were changed**

Run: `grep -c "MACOSX_DEPLOYMENT_TARGET = 15.0;" VercelBar.xcodeproj/project.pbxproj`
Expected: `2`

Run: `grep -c "MACOSX_DEPLOYMENT_TARGET = 14.0;" VercelBar.xcodeproj/project.pbxproj`
Expected: `0`

- [ ] **Step 3: Verify the project still builds**

Run: `xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add VercelBar.xcodeproj/project.pbxproj
git commit -m "chore: bump macOS deployment target to 15.0"
```

---

### Task 3: Add pull-to-refresh to the popover list

**Files:**
- Modify: `VercelBar/Views/PopoverView.swift` (extract the `ScrollView` at lines 18–36 into a new `RefreshableList` subview; add the subview)

**Interfaces:**
- Consumes: `store.manualRefresh()` and `store.isRefreshing` (Task 1); `onScrollGeometryChange` (Task 2).
- Produces: a private `RefreshableList<Content: View>` subview used inside `PopoverView.body`.

This task is UI/gesture code that is not unit-testable here (no UI test target exists); it is verified by build + manual check. There is no failing-test step — the deliverable is a successful build and the manual smoke test in Step 4.

- [ ] **Step 1: Replace the inline `ScrollView` with `RefreshableList`**

In `VercelBar/Views/PopoverView.swift`, replace the current block (lines 18–36):

```swift
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .deployments:
                        if store.deployments.isEmpty {
                            EmptyListPlaceholder(label: "No deployments")
                        } else {
                            ForEach(store.deployments) { DeploymentRow(deployment: $0) }
                        }
                    case .projects:
                        if store.projects.isEmpty {
                            EmptyListPlaceholder(label: "No projects")
                        } else {
                            ForEach(store.projects) { ProjectRow(project: $0, scopeName: store.scopeName) }
                        }
                    }
                }
            }
            .frame(height: 320)
```

with:

```swift
            RefreshableList(isRefreshing: store.isRefreshing) {
                await store.manualRefresh()
            } content: {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .deployments:
                        if store.deployments.isEmpty {
                            EmptyListPlaceholder(label: "No deployments")
                        } else {
                            ForEach(store.deployments) { DeploymentRow(deployment: $0) }
                        }
                    case .projects:
                        if store.projects.isEmpty {
                            EmptyListPlaceholder(label: "No projects")
                        } else {
                            ForEach(store.projects) { ProjectRow(project: $0, scopeName: store.scopeName) }
                        }
                    }
                }
            }
            .frame(height: 320)
```

- [ ] **Step 2: Add the `RefreshableList` subview**

In `VercelBar/Views/PopoverView.swift`, add this in the `// MARK: - Shared subviews` section (e.g. after `EmptyListPlaceholder`, before the final line):

```swift
// MARK: - Pull-to-refresh wrapper

/// macOS has no native pull-to-refresh, so we track the scroll view's vertical
/// content offset. A negative offset means the user is over-pulling past the
/// top. Crossing `triggerThreshold` while dragging arms a refresh; the refresh
/// fires once when the pull is armed, and `armed` resets only after the offset
/// returns near zero — preventing repeat triggers within one continuous drag.
private struct RefreshableList<Content: View>: View {
    let isRefreshing: Bool
    let onRefresh: () async -> Void
    @ViewBuilder let content: Content

    /// How far the user must over-pull (points) before a refresh arms.
    private let triggerThreshold: CGFloat = 60

    @State private var pull: CGFloat = 0   // positive = points pulled past the top
    @State private var armed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                spinner
                content
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            // Over-pull at the top makes contentOffset.y negative; expose it as
            // a positive "pull" distance, clamped at 0 for normal scrolling.
            max(0, -geo.contentOffset.y)
        } action: { _, newPull in
            pull = newPull
            if newPull >= triggerThreshold, !armed, !isRefreshing {
                armed = true
                Task {
                    await onRefresh()
                    armed = false
                }
            }
        }
    }

    @ViewBuilder private var spinner: some View {
        if isRefreshing || pull > 0 {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(isRefreshing ? 1 : min(1, pull / triggerThreshold))
                .opacity(isRefreshing ? 1 : min(1, pull / triggerThreshold))
                .frame(height: isRefreshing ? 28 : min(28, pull))
                .frame(maxWidth: .infinity)
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual smoke test**

Run the app (`xcodebuild ... build` then launch the built `.app`, or run from Xcode). Open the menubar popover and:
- Two-finger-drag the list downward past the top — a spinner should grow into view.
- Release past ~60pt of over-pull — the list refreshes (spinner stays solid briefly, `lastUpdated` advances, list reorders to newest-first).
- Normal scrolling within the list does **not** trigger a refresh.

- [ ] **Step 5: Commit**

```bash
git add VercelBar/Views/PopoverView.swift
git commit -m "feat: pull-to-refresh on popover list"
```

---

### Task 4: Full test + build verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -project VercelBar.xcodeproj -scheme VercelBar -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` — all existing tests plus `test_manualRefreshPopulatesAndResetsFlag` pass.

- [ ] **Step 2: Confirm clean tree of intended changes**

Run: `git status`
Expected: working tree shows only the pre-existing unrelated token-rotation changes (if any remain uncommitted); the pull-to-refresh work is committed across Tasks 1–3.

---

## Self-Review

**Spec coverage:**
- Store `isRefreshing` + `manualRefresh()` → Task 1 ✓
- Deployment target bump 14→15 → Task 2 ✓
- `RefreshableList` with `onScrollGeometryChange`, threshold, armed flag, revealed spinner → Task 3 ✓
- Test that `manualRefresh()` populates and resets flag → Task 1 Step 1 ✓
- Behavior (drag → spinner → release → refresh → spinner gone) → Task 3 Step 4 ✓
- Out of scope (refresh button, timer cadence) → not added ✓

**Type consistency:** `manualRefresh()`, `isRefreshing`, `RefreshableList(isRefreshing:onRefresh:content:)`, `triggerThreshold`, `armed`, `pull` are named identically everywhere they appear.

**Placeholder scan:** No TBD/TODO/"handle edge cases"; all code shown in full.
