# Multi-Provider Foundation — Design

**Date:** 2026-06-23
**Status:** Approved (design)

## Goal

Reshape VercelBar's architecture so that "Vercel" becomes one *provider group* among
others, leaving room for future GitHub and Azure DevOps providers, while shipping
**only Vercel working**. Add multi-account support, a grouped provider/account/team
dropdown, and an explicit "followed projects" concept (default: follow all new).

This is a **refactor-only** effort: GitHub/Azure DevOps appear in the model as
not-yet-implemented providers (visible but disabled in UI). No working non-Vercel
client is built here.

## Concepts

- **Provider** — `vercel` (implemented), `github` / `azureDevOps` (future). Knows its
  display name, icon, and `isImplemented` flag.
- **Account** — a connected login for a provider. Stable `id: UUID`, a `provider`, a
  display `label` (username), and a `credentialSource`:
  - `.vercelCLI` — the auto-detected Vercel CLI login on disk (read-only, no token in
    Keychain; continues to read `~/Library/Application Support/com.vercel.cli`).
  - `.keychain` — a manually-added account whose token lives in the macOS Keychain.
- **Scope** — an `Account` + optional team (Vercel personal vs. a team). The unit of
  polling.
- **Followed projects** — the set the user watches. Default: **follow all new**.
  Keyed by a **composite id** (`provider + accountId + projectId`) so names never
  collide across providers/accounts. Unfollowed projects are **hidden from the popover
  and silent**. Replaces today's `disabledProjects` opt-out (migrated — see below).

## Architecture

### New types

- `Models/Provider.swift` — enum with `displayName`, `iconName`, `isImplemented`.
- `Models/Account.swift` — `id`, `provider`, `label`, `credentialSource`. `Codable`.
  Non-secret metadata persisted in `UserDefaults`; secrets in Keychain.
- `Models/Scope.swift` — `account` + optional `teamId`/`teamName`.

### Clients

- `DeploymentProviderClient` protocol — `deployments(scope:)`, `projects(scope:)`,
  `teams(account:)`, `user(account:)`. The seam future providers slot into.
- `VercelClient` (+ `TeamsClient` / `UserClient`) become the Vercel conformance.

### Stores / services

- `Stores/AccountStore.swift` — owns connected accounts: detect the CLI login, add/remove
  manual accounts, Keychain read/write. Single source of truth for "what am I connected
  to." Knows nothing about deployments.
- `Services/KeychainCredentialStore.swift` — thin wrapper over Keychain for token
  storage/retrieval. Injectable (in-memory fake for tests).
- `DeploymentStore` becomes a **multi-scope aggregator** (see Data flow). Knows nothing
  about Keychain.
- `SettingsStore` gains the followed-projects API (composite keys + "auto-follow new"
  flag) and drops `disabledProjects` after migration.

### Boundaries

`AccountStore` ↔ Keychain; `DeploymentStore` ↔ provider clients; neither reaches across.
Each provider client is independently testable against the protocol.

## Data flow (per poll tick)

1. `DeploymentStore.poll()` reads followed scopes from `AccountStore` + `SettingsStore`.
2. Fan out one fetch per scope concurrently via `TaskGroup`.
3. Tag each `Deployment`/`Project` result with its source `Account`/`Provider`.
4. Merge, apply the follow filter, sort (newest first).
5. Diff against the previous snapshot for notifications — keyed by **composite project
   id**, so the same project name under two accounts never cross-notifies.

## UI

### Top-bar dropdown (popover) — grouped filter, default "All"

- `All followed` at top (checkmark when active).
- A section **per provider** (`Vercel`; future `GitHub` shown disabled / "coming soon").
  Under each provider: connected accounts; under each account: teams (personal + teams).
  Selecting any entry below "All" **filters** the aggregated list to that
  provider/account/team.
- Label reflects the active filter (e.g. `▲ All`, `▲ acme`).
- Trailing `Manage accounts…` item → Settings → Accounts.

### Popover lists (Deployments / Projects tabs)

- Show the merged, aggregated set of **followed** projects/deployments across all
  connected scopes, filtered by the dropdown.
- Each row gains a small **provider/account badge**, shown **only when more than one
  source is connected** (no clutter in the common single-account case).

### Settings

- **Account tab → Accounts:** lists connected accounts grouped by provider, each with
  identity (username/email/team) and a **Remove** action. An **"Add account"** button →
  choose provider → paste token (stored in Keychain). The Vercel CLI account is shown
  read-only ("from Vercel CLI"). Keeps the `vercel login` guidance.
- **New Projects tab/section:** an **"Automatically follow new projects"** toggle
  (default on), then the followed-projects list grouped by account with follow toggles.
  Replaces the per-project toggles currently under Notifications.

## Error handling

- **Per-source isolation:** each scope fetch succeeds or fails independently. A failing
  scope keeps its last-known data and records a per-source error; other scopes still
  update.
- The existing token-rotation + single-401-retry logic applies **per Vercel CLI scope**.
  Keychain-backed accounts that 401 repeatedly are marked **"needs re-auth"** rather than
  logging out the whole app.
- **Bottom status bar:** no errors → hidden (as today); one source → its message;
  multiple → "N accounts couldn't refresh" with detail surfaced in the dropdown/Settings.
- `iconState` aggregates across all followed deployments (failure > building > ready);
  `loggedOut` only when **no** account is usable.

## Migration

On first launch of the new version: read the existing `disabledProjects` (project
*names*). For each, mark the matching project as **unfollowed** under the Vercel CLI
account's composite key. Remove the `disabledProjects` default afterward. Also migrate
the existing `selectedTeamId` into the CLI account's default scope so the user's current
team selection is preserved.

## Testing

- `AccountStore`: CLI detection, add/remove, Keychain round-trip (in-memory fake store).
- Migration: `disabledProjects` (+ `selectedTeamId`) → followed/unfollowed composite keys
  and default scope.
- `SettingsStore` follow API: auto-follow-new behavior, composite keying.
- `DeploymentStore` aggregation: merge from multiple fake scopes; per-source error
  isolation; notification diffing keyed by composite id; filter-by-dropdown.
- `VercelClient` conformance to `DeploymentProviderClient` (existing tests adapted).

## Out of scope

- Working GitHub or Azure DevOps clients (model/UI placeholders only).
- OAuth sign-in flows (manual token entry only).
- Cross-provider deployment actions (redeploy, rollback, etc.).
