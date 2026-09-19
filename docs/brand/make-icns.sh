#!/bin/bash
# Builds DeployBar.icns from the iconset.
# Filenames here use "-at2x" because the export tool cannot write "@" — restore it first.
set -e
cd "$(dirname "$0")"
rm -rf build.iconset && cp -R DeployBar.iconset build.iconset
for f in build.iconset/*-at2x.png; do mv "$f" "${f/-at2x/@2x}"; done
iconutil -c icns build.iconset -o DeployBar.icns
rm -rf build.iconset
echo "wrote DeployBar.icns"
