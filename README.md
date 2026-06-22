# VercelBar

**Native macOS menu bar app for monitoring Vercel deployments at a glance.**

<!-- Replace <OWNER> throughout this file with the actual GitHub owner/org once the repo is public. -->

[![CI](https://github.com/<OWNER>/vercelbar/actions/workflows/ci.yml/badge.svg)](https://github.com/<OWNER>/vercelbar/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

<!-- Add a real screenshot here. Replace docs/screenshot.png with an actual capture of the popover. -->
<img src="docs/screenshot.png" alt="VercelBar popover showing deployment statuses" width="420" />

---

## Features

**Menu bar**
- ▲ icon with a colored status dot — green (all ready), amber (building), red (failure), gray (not logged in)
- Lives in the menu bar only; no Dock icon

**Deployments tab**
- Per-deployment rows: status dot, favicon, project name, commit message, branch, and timing ("started 3m ago · built in 56s")
- Click a successful deployment → opens the live site; click a failed deployment → opens build logs
- Row actions: open deployment, open build logs, open the source commit

**Projects tab**
- Favicon, project name, and stat chips — framework, production branch, environment variable count, Node version, cron count (when applicable)
- Quick links: open production site, edit environment variables, open repository
- Overflow menu (⋯): Analytics (when web analytics is enabled), project settings, Vercel dashboard

**Notifications**
- System notifications on deployment events
- Failure and Success alerts on by default; Started and Canceled off by default
- Per-project opt-out available in Settings

**Settings**
- Configurable poll interval (default 30 seconds)
- Four notification event toggles
- Per-project notification toggles
- Launch at login
- Account section showing the connected Vercel account and active team

---

## How It Works / Auth

VercelBar reuses your existing **Vercel CLI** session. On launch it reads:

| File | Purpose |
|------|---------|
| `~/Library/Application Support/com.vercel.cli/auth.json` | Your Vercel access token |
| `~/Library/Application Support/com.vercel.cli/config.json` | Your active team selection |

No separate API key setup is required. If you have already run `vercel login`, VercelBar is ready to go. The team switcher in the popover toolbar lets you switch between Personal and any team you belong to — this is stored locally and does not modify the Vercel CLI's own config.

**VercelBar is strictly read-only.** It never creates, modifies, or deletes any resource on Vercel.

**Privacy**: your token never leaves your machine. All network requests go only to `api.vercel.com` and to project domains for favicon fetching. Favicons are cached on disk.

---

## Requirements

- macOS 14.0 (Sonoma) or later
- [Vercel CLI](https://vercel.com/docs/cli) installed and logged in (`npm i -g vercel && vercel login`)

To **build from source**, you also need:
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

---

## Install

### From Source (recommended)

1. Install XcodeGen if you don't have it:

   ```bash
   brew install xcodegen
   ```

2. Clone the repository and generate the Xcode project:

   ```bash
   git clone https://github.com/<OWNER>/vercelbar.git
   cd vercelbar
   xcodegen generate
   ```

3. **Option A — Xcode**: open `VercelBar.xcodeproj`, select the `VercelBar` scheme, and press Run.

   **Option B — command line**: build and install to `/Applications`:

   ```bash
   xcodebuild -project VercelBar.xcodeproj \
              -scheme VercelBar \
              -configuration Release \
              -derivedDataPath build
   cp -R build/Build/Products/Release/VercelBar.app /Applications/
   ```

> **Gatekeeper note**: Because the app is currently unsigned, macOS may block it on first launch. Right-click (or Control-click) `VercelBar.app` in Finder and choose **Open**, then confirm in the dialog.

### Releases

Notarized release builds may be published on the [GitHub Releases](https://github.com/<OWNER>/vercelbar/releases) page. Check there for a drag-and-drop `.dmg` if you prefer not to build from source.

---

## Configuration

Open the popover and click the gear icon to open Settings.

| Setting | Default | Description |
|---------|---------|-------------|
| Poll interval | 30 seconds | How often VercelBar fetches from the Vercel API |
| Notify on Failure | On | System notification when a deployment fails |
| Notify on Success | On | System notification when a deployment succeeds |
| Notify on Started | Off | System notification when a deployment starts |
| Notify on Canceled | Off | System notification when a deployment is canceled |
| Per-project notifications | All on | Disable notifications for individual projects |
| Launch at login | Off | Start VercelBar automatically when you log in |

The Account section shows the currently connected Vercel user and the active team.

---

## Development

### Project Layout

```
VercelBar/
  Models/      — Deployment, Project, Team, VercelUser, StateTransition
  Clients/     — VercelClient, TeamsClient, UserClient, TokenProvider, ScopeResolver
  Stores/      — DeploymentStore (@Observable, drives the UI)
  Services/    — FaviconCache, FaviconURL, NotificationManager, LinkBuilder, LaunchAtLogin, DeploymentDiffer
  Views/       — PopoverView, DeploymentRow, ProjectRow, SettingsView, MenuBarIcon, StatChip, StatusDot, FaviconView
VercelBarTests/
  — ~98 unit tests covering decoding, diffing, notification gating, link building, scope resolution, and more
```

The architecture is layered: clients are pure value types that accept an injectable `fetch` closure, making them straightforward to test without network access. `DeploymentStore` is the single `@Observable` object that the SwiftUI views observe.

### Running Tests

```bash
xcodegen generate   # only needed once, or after editing project.yml
xcodebuild test \
  -project VercelBar.xcodeproj \
  -scheme VercelBar \
  -destination 'platform=macOS'
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on reporting issues and submitting pull requests.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Disclaimer

VercelBar is an unofficial, community-built project. It is not affiliated with, endorsed by, or supported by Vercel Inc.
