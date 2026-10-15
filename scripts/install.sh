#!/usr/bin/env bash
# Build MeetRec (ad-hoc signed) and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project MeetRec.xcodeproj -scheme MeetRec -configuration Release \
  -derivedDataPath build/dd build -quiet
pkill -x MeetRec 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/MeetRec.app
ditto build/dd/Build/Products/Release/MeetRec.app ~/Applications/MeetRec.app
open ~/Applications/MeetRec.app
echo "Installed ~/Applications/MeetRec.app"
