#!/bin/zsh
# Installs the latest Xcode-built HeartDrive onto the iPhone and Apple Watch via
# devicectl, bypassing Xcode's flaky "could not be installed at this time" GUI
# step and the unreliable Watch-app "Install" button.
#
# Usage: build HeartDrive in Xcode first (⌘B; the *build* works fine, only
# Xcode's install flakes), then run this script.
#
# Refresh the device IDs anytime with:  xcrun devicectl list devices
set -e

PHONE_ID="31D6C912-DDAE-5B9D-813F-2D80BC33921B"   # Eric's iPhone
WATCH_ID="00AEA51E-68D4-51B2-B0EC-F24F38C641E1"   # Little Rock (Apple Watch Ultra 2)

APP=$(ls -td $(find ~/Library/Developer/Xcode/DerivedData \
  -path '*Build/Products/Debug-iphoneos/HeartDrive.app' -maxdepth 7 2>/dev/null) 2>/dev/null | head -1)

if [ -z "$APP" ]; then
    echo "No build found. Build HeartDrive in Xcode first (⌘B), then re-run."
    exit 1
fi

echo "Installing: $APP"
echo "▶ iPhone…"
xcrun devicectl device install app --device "$PHONE_ID" "$APP" >/dev/null && echo "  ✓ iPhone"
echo "▶ Apple Watch…"
xcrun devicectl device install app --device "$WATCH_ID" "$APP/Watch/HeartDriveWatch.app" >/dev/null && echo "  ✓ Watch"
echo "Done. Open HeartDrive on the watch and allow the HealthKit prompt."
