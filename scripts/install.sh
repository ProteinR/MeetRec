#!/usr/bin/env bash
# Build MeetRec (ad-hoc signed) and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project MeetRec.xcodeproj -scheme MeetRec -configuration Release \
  -derivedDataPath build/dd build -quiet
# Re-sign with the stable local certificate (see AGENTS.md). Its designated requirement is the
# certificate, not the build hash, so Screen Recording / Microphone permissions survive rebuilds.
IDENTITY="dmemruk Local Code Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep -s "$IDENTITY" build/dd/Build/Products/Release/MeetRec.app
else
  echo "warning: certificate '$IDENTITY' not found; app stays ad-hoc signed and permissions reset on every rebuild" >&2
fi
pkill -x MeetRec 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/MeetRec.app
ditto build/dd/Build/Products/Release/MeetRec.app ~/Applications/MeetRec.app
open ~/Applications/MeetRec.app
echo "Installed ~/Applications/MeetRec.app"
