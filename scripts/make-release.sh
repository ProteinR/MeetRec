#!/usr/bin/env bash
# Build a Release MeetRec.app, sign it and pack it into build/release/MeetRec-<version>.dmg (the app
# and a link to /Applications) and a .zip. Used by .github/workflows/release.yml; works locally too.
# MEETREC_SIGN_IDENTITY names the signing certificate (CI: the release certificate imported from the
# repository secrets); without it the app stays ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml)
app=build/dd-release/Build/Products/Release/MeetRec.app
out=build/release
rm -rf build/dd-release "$out"
mkdir -p "$out"

xcodegen generate -q
xcodebuild -project MeetRec.xcodeproj -scheme MeetRec -configuration Release \
  -derivedDataPath build/dd-release -skipPackagePluginValidation -skipMacroValidation build -quiet

if [ -n "${MEETREC_SIGN_IDENTITY:-}" ]; then
  # A stable certificate: macOS ties Screen Recording / Microphone permissions to it, so they
  # survive updates (see README, "Signing").
  codesign --force --deep -s "$MEETREC_SIGN_IDENTITY" "$app"
  codesign --verify --deep --strict "$app"
  codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
else
  echo "warning: MEETREC_SIGN_IDENTITY not set; the release stays ad-hoc signed" >&2
fi

ditto -c -k --keepParent "$app" "$out/MeetRec-$version.zip"
stage=$(mktemp -d)
ditto "$app" "$stage/MeetRec.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "MeetRec $version" -srcfolder "$stage" -format UDZO \
  -fs HFS+ "$out/MeetRec-$version.dmg"
rm -rf "$stage"
# The build copy would show up as another MeetRec in Launchpad / Spotlight.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/$app" 2>/dev/null || true
rm -rf "$app"
ls -l "$out"
