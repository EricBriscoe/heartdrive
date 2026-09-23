#!/bin/zsh
# Type-check both targets against the active Xcode SDKs without building assets.
# Release archives and device checks remain separate verification steps.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
WATCH_SDK=$(xcrun --sdk watchos --show-sdk-path)

echo "▶ iOS type-check"
xcrun swiftc -sdk "$IOS_SDK" -target arm64-apple-ios17.0 -typecheck \
  $(find HeartDrive/Sources Shared -name '*.swift')
echo "✓ iOS OK"

echo "▶ watchOS type-check"
xcrun swiftc -sdk "$WATCH_SDK" -target arm64_32-apple-watchos10.0 -typecheck \
  $(find HeartDriveWatch/Sources Shared -name '*.swift')
echo "✓ watchOS OK"
