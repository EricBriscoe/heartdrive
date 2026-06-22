#!/bin/zsh
# Archives + exports a distribution IPA for App Store / TestFlight, then optionally
# uploads. Forces the system rsync because Homebrew's rsync 3.4.x breaks
# `xcodebuild -exportArchive` ("rsync: syntax or usage error … Copy failed").
#
# To auto-upload, create an App Store Connect API key (App Store Connect ▸ Users
# and Access ▸ Integrations), drop AuthKey_<KEYID>.p8 in
# ~/.appstoreconnect/private_keys/, and run with:
#   ASC_KEY_ID=XXXX ASC_ISSUER_ID=yyyy ./scripts/release.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARCHIVE=/tmp/HeartDrive.xcarchive
EXPORT=/tmp/HeartDriveExport

echo "▶ Archiving (Release)…"
xcodebuild archive -project HeartDrive.xcodeproj -scheme HeartDrive \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -quiet

echo "▶ Exporting IPA (system rsync)…"
rm -rf "$EXPORT"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates -quiet

IPA="$EXPORT/HeartDrive.ipa"
echo "✓ IPA: $IPA"

if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ]; then
  echo "▶ Uploading to App Store Connect…"
  xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "✓ Uploaded. It'll appear in TestFlight after ~10 min of processing."
else
  echo "ℹ Set ASC_KEY_ID / ASC_ISSUER_ID to auto-upload, or drag the IPA into Transporter."
fi
