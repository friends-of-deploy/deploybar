#!/usr/bin/env bash
# Append one release to a Sparkle appcast, in place.
#
# Sparkle ships `generate_appcast`, but it wants a directory holding every past
# build so it can compute deltas, and CI has exactly one. This writes the single
# <item> the release produces instead. No deltas — at roughly 5 MB per build,
# full replacement is fine.
#
# Usage:
#   append-appcast.sh FEED VERSION BUILD ZIP_URL LENGTH SIGNATURE NOTES_FILE
set -euo pipefail

if [ "$#" -ne 7 ]; then
  echo "usage: $(basename "$0") FEED VERSION BUILD ZIP_URL LENGTH SIGNATURE NOTES_FILE" >&2
  exit 2
fi

FEED="$1"
VERSION="$2"
BUILD="$3"
ZIP_URL="$4"
LENGTH="$5"
SIGNATURE="$6"
NOTES_FILE="$7"

[ -f "$FEED" ] || { echo "no such feed: $FEED" >&2; exit 1; }
[ -f "$NOTES_FILE" ] || { echo "no such notes file: $NOTES_FILE" >&2; exit 1; }

# RFC 822, which is what the RSS pubDate field wants.
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Release notes are author-written Markdown and routinely contain & and <, so
# they go in a CDATA section. The only sequence CDATA cannot carry is its own
# terminator; splitting it across two sections is the standard escape.
NOTES="$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES_FILE")"

ITEM_FILE="$(mktemp)"
trap 'rm -f "$ITEM_FILE"' EXIT

cat > "$ITEM_FILE" <<ITEM
    <item>
      <title>${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
${NOTES}
]]></description>
      <enclosure url="${ZIP_URL}"
                 length="${LENGTH}"
                 type="application/octet-stream"
                 sparkle:edSignature="${SIGNATURE}" />
    </item>
ITEM

# Newest first: insert directly after the opening <channel> tag rather than
# appending at the end, so readers see the latest release first.
TMP="$(mktemp)"
awk -v item_file="$ITEM_FILE" '
  !done && /<channel>/ {
    print
    while ((getline line < item_file) > 0) print line
    close(item_file)
    done = 1
    next
  }
  { print }
  END { if (!done) { print "append-appcast: no <channel> element found" > "/dev/stderr"; exit 1 } }
' "$FEED" > "$TMP"

mv "$TMP" "$FEED"
echo "appended ${VERSION} (build ${BUILD}) to $(basename "$FEED")"
