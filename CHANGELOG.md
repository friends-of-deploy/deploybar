# Changelog

Release notes for DeployBar. Earlier releases are available on
[GitHub Releases](https://github.com/friends-of-deploy/deploybar/releases).

## [1.2.0] - 2026-09-20

DeployBar 1.2 makes getting started easier and brings your personal accounts,
GitHub organizations, and Vercel teams into one clearer view. It also adds more
control over notifications and optional, privacy-conscious crash reporting.

### A guided start

- A new three-step welcome window introduces DeployBar, shows detected accounts,
  and lets you choose notifications, launch at login, and crash reporting. New
  installations see it automatically; existing connected installations keep their
  usual startup. You can reopen the guide from General settings.
- The empty menu now explains how to connect an account and takes you straight
  to setup. GitHub and Vercel artwork makes accounts easier to recognize throughout
  the guide, source menu, and Settings.
- Token-based connections validate your GitHub or Vercel identity before saving
  credentials in Keychain, show actionable errors, and refresh after connecting.
  You can rename both token and CLI accounts without changing their credentials.
- The guide includes English and Polish copy and respects Reduce Motion.

### Accounts and organizations together

- Browse personal accounts, GitHub organizations, and Vercel teams from a flatter
  source menu, or choose All to combine your enabled sources.
- Each account has an Organizations settings tab. Turn individual organizations
  on or off and give them their own marker colors; organizations inherit the
  account color until you choose an override.
- Disabled organizations disappear immediately and stop contributing requests
  and notifications. Switching between individual sources uses already fetched data,
  without starting an unnecessary refresh.
- Polling rotates through larger sets of organizations, bounds concurrent work,
  and retains cached rows between turns. Settings shows the effective refresh
  interval so you can see when a larger account takes longer to update.
- Organization discovery works with fine-grained GitHub tokens and newly added
  token accounts. GitHub polling accounts for repository pagination and workflow
  fan-out, including when a short refresh interval needs to be slowed down.
- Restored and newly discovered scopes establish their own notification baseline,
  avoiding alerts for historical runs as the polling rotation reaches them.
  Disabling a scope also discards results still arriving from an earlier refresh.

### Notifications that fit your workflow

- Choose whether clicking a notification opens the deployment or workflow run,
  or the deployment's live URL. If no live URL is available, DeployBar opens the
  deployment or run instead.
- The notification's Mute action now lets you silence that event type everywhere
  or mute only the project. Muting a project's alerts does not hide its rows.
- Notification permission is requested when you explicitly enable notifications
  in onboarding or Settings, instead of interrupting app startup.

### Clearer status and native windows

- New menu bar badges distinguish success, failure, and signed-out states by
  shape. Opening the popover acknowledges completed outcomes; active builds keep
  their running indicator.
- Settings temporarily gives DeployBar a Dock icon, making its window easier to
  find and restore. Closing Settings returns it to its usual menu bar behavior.

### Optional crash reports

- Share crash reports is **off by default**, with the same preference available
  in onboarding and General settings. Enabling it sends sanitized technical crash
  reports through Sentry; turning it off stops collection and clears pending
  local reports.
- Reporting excludes account details, tokens, repository names, deployment URLs,
  and build logs. Application logs, usage analytics, session tracking, and
  performance tracing are not enabled.
- Release builds now preserve debugging symbols and upload them when Sentry is
  configured, so received crash reports can identify the failing code. Consent
  boundaries also prevent older reports from being sent after reporting is
  disabled and later enabled again.

### Release documentation

- The repository changelog now supplies the GitHub release notes and the in-app
  changelog through the update feeds, keeping all three descriptions consistent.
- A reusable repository release skill documents versioning, checks, publishing,
  and verification of GitHub, Sparkle, and Homebrew delivery.

[Full changes since 1.1.2](https://github.com/friends-of-deploy/deploybar/compare/v1.1.2...v1.2.0)
