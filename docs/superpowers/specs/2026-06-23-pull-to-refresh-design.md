# Pull-to-Refresh on the Popover List

**Date:** 2026-06-23
**Status:** Approved

## Goal

When the user pulls the deployments/projects list down with the trackpad, run a
manual refresh and show a loading indicator while it runs.

## Context

VercelBar is a macOS menubar app. The popover (`PopoverView`) shows a `ScrollView`
of deployments or projects, polled on a timer by `DeploymentStore.poll()`.

macOS has **no native pull-to-refresh**: SwiftUI's `.refreshable` is a no-op on
macOS, and `ScrollView` provides no built-in helper. The gesture must be built
manually by tracking scroll offset.

## Decisions

- **Approach:** Custom pull-down gesture (matches the request), not a refresh button.
- **Scroll API:** `onScrollGeometryChange` (macOS 15+). The project's deployment
  target is bumped from 14.0 → 15.0 to allow this cleaner API.

## Changes

### 1. `DeploymentStore.swift`

- Add observable state: `var isRefreshing = false`.
- Add `func manualRefresh() async`:
  - Sets `isRefreshing = true`, calls `poll()`, resets `isRefreshing = false`
    via `defer`.
  - Reuses existing `poll()`, which already guards re-entrancy with
    `isPollInFlight`, so overlapping triggers are safe.

### 2. Deployment target (`VercelBar.xcodeproj/project.pbxproj`)

- Change both `MACOSX_DEPLOYMENT_TARGET = 14.0;` entries to `15.0`.

### 3. `PopoverView.swift`

- Extract a `RefreshableList` subview wrapping the existing `ScrollView`.
- Track over-pull using `.onScrollGeometryChange(for: CGFloat.self)` reading the
  vertical content offset.
- When over-pulled past a threshold (~60pt) and the gesture settles, call
  `await store.manualRefresh()`.
- An "armed" flag prevents repeat triggers within one continuous pull; it resets
  when the offset returns to ~0.
- A `ProgressView` spinner is revealed in the over-pull region and stays visible
  while `store.isRefreshing` is true.

### 4. Tests (`DeploymentStoreTests.swift`)

- Add a test that `manualRefresh()` populates `deployments` from the mock client
  and leaves `isRefreshing == false` after completion.

## Behavior

Drag the list down → spinner is revealed → release past threshold →
`manualRefresh()` runs → list updates → spinner disappears.

## Out of scope

- A separate refresh button.
- Changing the existing timer-based polling cadence.
