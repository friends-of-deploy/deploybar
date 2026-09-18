#!/usr/bin/env bash
# Launch DeployBar against a fixture world, for documentation screenshots.
#
#   scripts/demo.sh                     # live simulation, Debug build
#   scripts/demo.sh --freeze            # pinned demo data clock
#   scripts/demo.sh --release           # build and run the Release configuration
#   scripts/demo.sh --scenario onboarding
#
# --freeze pins the demo data clock so the fixture world stops advancing.
# Relative timestamps in the UI (e.g. "started 7m ago") are still formatted
# against the live system clock, so they will keep advancing even with
# --freeze; two runs are not guaranteed to be byte-identical.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="Debug"
SCENARIO="default"
FREEZE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --freeze)   FREEZE="1"; shift ;;
    --release)  CONFIGURATION="Release"; shift ;;
    --scenario) SCENARIO="${2:?--scenario needs a name}"; shift 2 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

echo "==> Building DeployBar ($CONFIGURATION)"
xcodebuild build \
  -project DeployBar.xcodeproj \
  -scheme DeployBar \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

APP_PATH="$(xcodebuild -project DeployBar.xcodeproj -scheme DeployBar \
  -configuration "$CONFIGURATION" -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')"

if [[ ! -d "$APP_PATH" ]]; then
  echo "could not locate the built app (looked for: $APP_PATH)" >&2
  exit 1
fi

echo "==> Stopping any running DeployBar"
pkill -x DeployBar 2>/dev/null || true
# Give the menu bar item a moment to disappear before the next one appears.
while pgrep -x DeployBar >/dev/null 2>&1; do sleep 0.1; done

echo "==> Launching demo (scenario: $SCENARIO${FREEZE:+, frozen})"
DEMO_ENV=(DEPLOYBAR_DEMO=1 "DEPLOYBAR_DEMO_SCENARIO=$SCENARIO")
if [[ -n "$FREEZE" ]]; then
  DEMO_ENV+=(DEPLOYBAR_DEMO_FREEZE=1)
fi
env "${DEMO_ENV[@]}" "$APP_PATH/Contents/MacOS/DeployBar" &

echo "==> Running. Stop with: pkill -x DeployBar"
