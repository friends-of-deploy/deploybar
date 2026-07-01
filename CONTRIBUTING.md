# Contributing to DeployBar

Thank you for your interest in contributing! Whether it's a bug fix, a new feature, or a documentation improvement, contributions are very welcome.

## Prerequisites

- macOS 14 or later
- Xcode (latest stable recommended)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [Vercel CLI](https://vercel.com/docs/cli) logged in (`vercel whoami`) for manual testing

## Project Setup

Clone the repo and regenerate the Xcode project:

```sh
git clone https://github.com/friends-of-deploy/deploybar.git
cd deploybar
xcodegen generate
open DeployBar.xcodeproj
```

> **Source of truth**: `project.yml` defines the project structure — not the `.xcodeproj`.
> After adding or removing source files you **must** re-run `xcodegen generate` and commit the regenerated `.xcodeproj` alongside your changes.

## Build & Test

**Build:**

```sh
xcodebuild -project DeployBar.xcodeproj -scheme DeployBar -destination 'platform=macOS' build
```

**Run tests:**

```sh
xcodebuild test -project DeployBar.xcodeproj -scheme DeployBar -destination 'platform=macOS'
```

## Architecture Conventions

The codebase is organized in clear layers:

| Layer | Responsibility |
|---|---|
| `Models/` | Codable value types matching the Vercel API |
| `Clients/` | Network access with an injectable `fetch` closure (enables offline unit tests) |
| `Stores/` | `@MainActor @Observable` state, owned by the app lifetime |
| `Services/` | Business logic that coordinates clients and stores |
| `Views/` | Thin SwiftUI — no business logic, no direct network calls |

Pure logic (clients, services, stores) belongs in unit tests. Views are build-verified. New behavior should come with tests.

## Tests & Fixtures

There are ~98 unit tests. Tests use real-shaped (but anonymized) JSON fixtures located in `DeployBarTests/Fixtures/`.

**Keep fixtures anonymized.** Never commit real account data, API tokens, email addresses, or identifiable project names. If you add a new fixture, anonymize all personal or account-specific fields before committing.

## Pull Requests

1. Branch off `main`: `git checkout -b your-feature-or-fix`
2. Keep PRs focused — one logical change per PR
3. Ensure all tests pass before opening a PR
4. Fill out the PR template (summary, how you tested, checklist)
5. Reference any related issue (`Closes #123`)

## Reporting Bugs or Requesting Features

Use the [issue templates](.github/ISSUE_TEMPLATE/) — they guide you through the information needed to act on your report quickly.

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to abide by its terms.
