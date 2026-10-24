#!/usr/bin/env bash
# Build MeetRec, sign it with a local certificate and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project MeetRec.xcodeproj -scheme MeetRec -configuration Release \
  -derivedDataPath build/dd build -quiet
# Re-sign with the stable local certificate (see AGENTS.md). Its designated requirement is the
# certificate, not the build hash, so Screen Recording / Microphone permissions survive rebuilds.
# MEETREC_SIGN_IDENTITY names it; else the first of the usual names found (README: how to make one).
IDENTITY="${MEETREC_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  for name in "MeetRec Local Code Signing" "dmemruk Local Code Signing"; do
    if security find-certificate -c "$name" >/dev/null 2>&1; then IDENTITY="$name"; break; fi
  done
fi
if [ -n "$IDENTITY" ] && security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  # PROFILE=1: also allow attaching tools (leaks, heap, Instruments); same certificate, so the
  # permissions stay.
  if [ "${PROFILE:-0}" = "1" ]; then
    codesign --force --deep -s "$IDENTITY" --entitlements scripts/profile.entitlements build/dd/Build/Products/Release/MeetRec.app
  else
    codesign --force --deep -s "$IDENTITY" build/dd/Build/Products/Release/MeetRec.app
  fi
else
  echo "warning: no signing certificate found (set MEETREC_SIGN_IDENTITY, see README); app stays ad-hoc signed and permissions reset on every rebuild" >&2
fi
# Quit gracefully (removes the crash-watchdog flag, so the watchdog does not relaunch the old copy);
# kill only if it does not quit in time.
if pgrep -qx MeetRec; then
  osascript -e 'tell application id "com.dmemruk.MeetRec" to quit' >/dev/null 2>&1 || true
fi
for _ in $(seq 1 50); do pgrep -qx MeetRec || break; sleep 0.2; done
pkill -x MeetRec 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/MeetRec.app
ditto build/dd/Build/Products/Release/MeetRec.app ~/Applications/MeetRec.app
# The build copy would show up as a second MeetRec in Launchpad / Spotlight: remove it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/build/dd/Build/Products/Release/MeetRec.app" 2>/dev/null || true
rm -rf build/dd/Build/Products/Release/MeetRec.app
open ~/Applications/MeetRec.app
echo "Installed ~/Applications/MeetRec.app"
