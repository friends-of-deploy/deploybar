---
name: deploybar-release
description: Use when preparing or publishing a DeployBar version, writing its changelog or release notes, or completing a commit, push, and release request for this repository.
---

# DeployBar release

Publish a verified macOS release whose repository changelog, GitHub release, and
in-app changelog describe the same shipped behavior. Follow the user's requested
scope and channel. A request to commit, push, and release authorizes that sequence;
a request for release notes alone does not authorize publishing.

## Establish the release boundary

- Inspect status, staged/unstaged diffs, and relevant untracked files before staging.
  Review binaries/assets by their purpose and provenance; keep secrets and build
  output out of Git. Preserve work outside the requested scope.
- Record HEAD and the latest published release tag. “Since the last commit” means
  the current working changes, but release notes must also cover unpublished commits
  since the last release. Read implementations/tests rather than paraphrasing subjects.
- Fetch remote refs, inspect branch divergence and published stable/beta appcasts,
  and select an unused version. Prefer a minor version for new user-facing features
  and a patch for fixes. Follow an explicitly requested version/channel.
- Set `MARKETING_VERSION` and increase `CURRENT_PROJECT_VERSION` in `project.yml`.
  The build number must exceed published builds in both channels. Regenerate with
  `xcodegen generate`; commit the generated project, not the ignored Info.plist.

## Author one source of release notes

Add a dated `## [VERSION] - YYYY-MM-DD` entry to `CHANGELOG.md`, newest first.
Use the repository's English release copy unless instructed otherwise. Lead with
what users gain, then group concrete changes under short headings. Include notable
fixes, privacy defaults, and upgrade implications. Distinguish implemented behavior
from proposals; an icon asset does not mean a provider is supported.

Extract the entry with `python3 scripts/release-notes.py VERSION` and read the
result as a standalone announcement. Use simple headings, paragraphs, bullets,
and links supported by the app's Markdown renderer. Include the previous-release
comparison link. Avoid a separate manually maintained copy of the same notes.

`.github/workflows/release.yml` passes this extracted body to GitHub before
`scripts/append-appcast.sh` copies it to Sparkle. `ChangelogLoader` reads those feeds
for the in-app Changelog. Editing the GitHub body after publication alone does not
update the app: synchronize the corresponding feed entry when correcting notes.

## Verify, commit, and publish

1. Run the full macOS test scheme with signing disabled, a Release build, and
   `bash scripts/test-append-appcast.sh`. Run release-notes script tests and workflow
   validation when changing the publication path. Inspect `git diff --check` and
   the complete staged contents. Match the release workflow's SDK requirement.
2. Commit the reviewed scope, push the intended branch, and wait for successful CI
   on that exact SHA. Resolve failures before tagging. Do not force-push or move an
   already published tag to repair a release.
3. Create and push the version tag at the verified SHA. The tag triggers signing,
   notarization, DMG/ZIP publication, Sentry symbols, Sparkle feeds and, for stable
   releases, Homebrew. `-beta` releases update only the beta feed and skip Homebrew.
4. Monitor the entire Release run, not just creation of the GitHub release. On
   failure inspect logs and existing assets/feed entries before retrying: the
   appcast script prepends entries and is not idempotent. Retry only the failed work
   when safe; otherwise report the concrete blocker without claiming completion.
   If only Homebrew failed, verify both feeds and update only the cask using the
   already published DMG's SHA-256. If a feed is missing the release, add only that
   missing entry; never duplicate an entry in the other feed.

## Verify delivery

Check remote branch/tag SHAs, published release body and DMG/ZIP assets, and the
publicly served appcast version, build, notes, ZIP length/URL and signature. Stable
releases must appear in both feeds. Verify the Homebrew cask version/checksum or
report that its optional step was skipped. Keep credentials in GitHub Actions
secrets; never add them to the skill or release notes. Do not enable paid services.

Return the version/build, commit and release links, a short user-facing change
summary, and verified checks. Name any incomplete distribution step explicitly.
