#!/bin/zsh
# Verify, archive and export the embedded iOS/watchOS apps, then optionally upload.
# AuthKey_<KEYID>.p8 stays in ~/.appstoreconnect/private_keys/.
# ASC_KEY_ID=<key-id> ASC_ISSUER_ID=<issuer-id> ./scripts/release.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEY_ID="${ASC_KEY_ID:-}"
ISSUER_ID="${ASC_ISSUER_ID:-}"
if [[ (-n "$KEY_ID" && -z "$ISSUER_ID") || (-z "$KEY_ID" && -n "$ISSUER_ID") ]]; then
  echo "Set both ASC_KEY_ID and ASC_ISSUER_ID, or neither." >&2
  exit 1
fi

./scripts/check.sh
xcodegen generate
if ! grep -q 'Embed Watch Content' HeartDrive.xcodeproj/project.pbxproj; then
  echo "Generated project is missing the embedded watch app." >&2
  exit 1
fi

# Unique paths prevent stale exports and do not overwrite earlier release artifacts.
RELEASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/heartdrive-release.XXXXXX")
ARCHIVE="$RELEASE_DIR/HeartDrive.xcarchive"
EXPORT="$RELEASE_DIR/export"
echo "Release artifacts: $RELEASE_DIR"
echo "▶ Archiving (Release)…"
xcodebuild archive -project HeartDrive.xcodeproj -scheme HeartDrive \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -quiet

APP="$ARCHIVE/Products/Applications/HeartDrive.app"
WATCH="$APP/Watch/HeartDriveWatch.app"
if [[ ! -d "$WATCH" ]]; then
  echo "Watch app is missing from the archive." >&2
  exit 1
fi
for KEY in CFBundleVersion CFBundleShortVersionString; do
  PHONE_VALUE=$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$APP/Info.plist")
  WATCH_VALUE=$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$WATCH/Info.plist")
  if [[ "$PHONE_VALUE" != "$WATCH_VALUE" ]]; then
    echo "Phone/watch $KEY mismatch." >&2
    exit 1
  fi
done

# Homebrew rsync is incompatible with Xcode's export invocation.
echo "▶ Exporting IPA (system rsync)…"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates -quiet
IPA="$EXPORT/HeartDrive.ipa"
[[ -s "$IPA" ]] || { echo "Export produced no IPA." >&2; exit 1; }
echo "✓ IPA: $IPA"

if [[ -n "$KEY_ID" ]]; then
  echo "▶ Uploading to App Store Connect…"
  xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"
  echo "✓ Upload accepted. Confirm processing and tester access in TestFlight."
else
  echo "Export only. Set ASC_KEY_ID / ASC_ISSUER_ID to upload, or use Transporter."
fi
