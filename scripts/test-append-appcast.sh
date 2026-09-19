#!/usr/bin/env bash
# Exercises append-appcast.sh the way the release workflow calls it.
#
# The routing rule this pins — stable goes to both feeds, beta only to the beta
# feed — is invisible until a release reaches the wrong people, so it is worth
# a test that runs on every push.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

cp "$HERE/fixtures/appcast-empty.xml" "$WORK/appcast.xml"
cp "$HERE/fixtures/appcast-empty.xml" "$WORK/appcast-beta.xml"
printf 'Fixed a thing.\n' > "$WORK/notes.md"

# --- a stable release lands in both feeds ---
"$HERE/append-appcast.sh" "$WORK/appcast.xml" "1.2.0" "4" \
  "https://example.com/DeployBar-1.2.0.zip" "1234" "sigSTABLE==" "$WORK/notes.md"
"$HERE/append-appcast.sh" "$WORK/appcast-beta.xml" "1.2.0" "4" \
  "https://example.com/DeployBar-1.2.0.zip" "1234" "sigSTABLE==" "$WORK/notes.md"

# --- a beta release lands only in the beta feed ---
"$HERE/append-appcast.sh" "$WORK/appcast-beta.xml" "1.3.0-beta.1" "5" \
  "https://example.com/DeployBar-1.3.0-beta.1.zip" "2345" "sigBETA==" "$WORK/notes.md"

xmllint --noout "$WORK/appcast.xml" || fail "stable feed is not well-formed XML"
xmllint --noout "$WORK/appcast-beta.xml" || fail "beta feed is not well-formed XML"

notes_format="$(xmllint --xpath \
  'string(/rss/channel/item[1]/description/@*[local-name()="format"])' \
  "$WORK/appcast.xml")"
[ "$notes_format" = "markdown" ] || \
  fail "expected embedded release notes to declare markdown format, got '$notes_format'"

grep -q '1.2.0' "$WORK/appcast.xml" || fail "stable feed is missing the stable release"
grep -q 'sigSTABLE==' "$WORK/appcast.xml" || fail "stable feed is missing the signature"

grep -q 'beta' "$WORK/appcast-beta.xml" || fail "beta feed is missing the beta release"
grep -q '1.2.0' "$WORK/appcast-beta.xml" || fail "beta feed is missing the stable release"

# The whole point of two feeds.
if grep -q 'beta' "$WORK/appcast.xml"; then
  fail "beta release leaked into the stable feed"
fi

# One item per append, no duplicates, no lost entries.
stable_items="$(grep -c '<item>' "$WORK/appcast.xml")"
beta_items="$(grep -c '<item>' "$WORK/appcast-beta.xml")"
[ "$stable_items" -eq 1 ] || fail "expected 1 item in the stable feed, found $stable_items"
[ "$beta_items" -eq 2 ] || fail "expected 2 items in the beta feed, found $beta_items"

# Newest first: the most recent append has to be the first <item> in the file.
first_title="$(grep -m1 '<title>' "$WORK/appcast-beta.xml" | sed -E 's/.*<title>(.*)<\/title>.*/\1/')"
[ "$first_title" = "1.3.0-beta.1" ] || fail "newest release is not first; got '$first_title'"

# Release notes have to survive intact, and characters that would break XML
# have to be escaped rather than dropped.
printf 'Fixed <b>bold</b> & ampersands.\n' > "$WORK/tricky.md"
"$HERE/append-appcast.sh" "$WORK/appcast.xml" "1.2.1" "6" \
  "https://example.com/DeployBar-1.2.1.zip" "3456" "sigESC==" "$WORK/tricky.md"
xmllint --noout "$WORK/appcast.xml" || fail "unescaped release notes broke the feed"
grep -q 'bold' "$WORK/appcast.xml" || fail "release notes were dropped"

# A missing feed or notes file must fail loudly, not silently produce nothing.
if "$HERE/append-appcast.sh" "$WORK/nope.xml" "1" "1" "u" "1" "s" "$WORK/notes.md" 2>/dev/null; then
  fail "a missing feed file should be an error"
fi

echo "PASS: append-appcast.sh"
