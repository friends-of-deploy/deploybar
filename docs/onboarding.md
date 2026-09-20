# Onboarding

DeployBar presents a native welcome window on the first unconfigured launch,
including when CLI credentials are detected for the first time. Existing saved
accounts keep the usual quiet launch. Closing the guide suppresses future
automatic presentation without marking setup complete.

The guide can be reopened from **Settings → General → Show welcome guide** or
from the menu bar's empty state. It has three steps: a product introduction,
detected providers, and optional notifications / launch at login / crash reports.
Crash reporting is off by default and shares its preference with General settings.
Each provider
has one complete card, regardless of how many accounts are available. Manual
accounts are added in Account Settings, linked directly from the guide. Tokens
are verified before saving to Keychain; leaving the settings form clears token
input and cancels an in-flight connection. The welcome window has no title bar
and embeds the native macOS close control in its content. Notification authorization is requested
only from an explicit Enable action, also available in notification settings.

Motion respects Reduce Motion, and all copy is available in English and Polish.

## Preview

Run with isolated demo data and no accounts:

```sh
DEPLOYBAR_ONBOARDING=1 scripts/demo.sh --scenario onboarding --freeze
```

Use the default scenario to check the connected-account layout:

```sh
DEPLOYBAR_ONBOARDING=1 scripts/demo.sh --freeze
```

Demo account data and onboarding preferences use separate defaults from the
real application. Notification permissions and login items are still OS-managed;
leave those controls unchanged during visual checks.

## Verification

`OnboardingTests` covers first launch, existing installations, dismissal,
completion, token trimming, validation failures and retries, cancellation,
and rollback when Keychain cannot save a credential. Run the regular Xcode test
scheme; `LocalizationTests` checks Polish catalog completeness.
