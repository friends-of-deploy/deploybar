# Crash reporting

DeployBar uses Sentry Cocoa 9.29.0 for optional crash reporting. The DSN is a
public ingestion address, not an authentication secret. No analytics SDK is
included in this integration.

## User choice

**Share crash reports** is off by default for both new and existing installations.
The onboarding Preferences step and Settings → General → Privacy share the same
persisted preference. Enabling it starts crash reporting immediately; on later
launches it starts before account discovery and deployment polling. Closing or
reopening onboarding does not change the choice.

Disabling it revokes event capture, cancels Sentry's network session, closes the
SDK, and removes its dedicated local cache. Already delivered reports cannot be
recalled by this switch. Demo and XCTest processes never start the app's reporter.

## Data

Reports contain crash types, stack addresses/symbols, binary debug identifiers,
the app version/build, macOS version, and basic hardware information. They exclude
account identity, provider tokens, repository/project names, deployment URLs,
build logs, HTTP requests, breadcrumbs, free-form exception messages, and local
directory paths. Memory introspection, session analytics, tracing, profiling,
screenshots, attachments, and automatic HTTP error reporting are disabled.

The in-app **What is shared?** explanation covers this scope. Crash reports go to
`o4512118384623616.ingest.de.sentry.io` only after opting in. As with any network
connection, the receiving server sees the source IP address. In Sentry's project
security/privacy settings, enable **Prevent Storing of IP Addresses**: Cocoa's
`sendDefaultPii = false` alone does not guarantee server-side IP removal.

## Release symbols

The release workflow preserves archive dSYMs as a GitHub Actions artifact. To also
upload them automatically, configure these repository Actions settings:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `SENTRY_AUTH_TOKEN` | A Sentry token permitted to upload debug information |
| Variable | `SENTRY_ORG` | Organization slug from the Sentry dashboard URL |
| Variable | `SENTRY_PROJECT` | Project slug from the Sentry dashboard URL |

These credentials stay in CI and never enter the app. Upload is skipped until all
three values are present. Sentry CLI also accepts numeric IDs. This repository uses
organization `deploybar` and project `deploybar-macos`. A configured upload failure
fails the release before publication.

## Verification

Run the unit tests with:

```sh
xcodegen generate
xcodebuild test -project DeployBar.xcodeproj -scheme DeployBar \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

For an end-to-end check, use a development build, explicitly enable **Share crash
reports**, and capture a synthetic event from the Xcode debugger after importing
Sentry, for example `SentrySDK.capture(message: "DeployBar verification")`. The
sanitizer replaces free-form message text with `DeployBar crash report`. Resume the
app so the upload can finish, then check the `development` environment in Sentry.

To verify native crashes, use a disposable development build with a temporary
`fatalError` action. Launch without the debugger, enable reporting, trigger the
crash, and relaunch with reporting still enabled. Sentry sends native crash reports
on the next launch; an attached debugger intercepts them. Never ship this test
action. Verify that turning reporting off prevents later capture and upload.
