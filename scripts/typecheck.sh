#!/bin/zsh
# Type-checks both targets against their SDKs without the simulator/destination
# subsystem (which is broken on this machine due to a CoreSimulator version skew).
# Full device builds should be done from Xcode.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IOS_SDK=$(xcrun --sdk iphoneos26.5 --show-sdk-path)
WATCH_SDK=$(xcrun --sdk watchos26.5 --show-sdk-path)

echo "▶ iOS type-check"
xcrun swiftc -sdk "$IOS_SDK" -target arm64-apple-ios17.0 -typecheck \
  $(find HeartDrive/Sources Shared -name '*.swift')
echo "✓ iOS OK"

echo "▶ watchOS type-check"
xcrun swiftc -sdk "$WATCH_SDK" -target arm64_32-apple-watchos10.0 -typecheck \
  $(find HeartDriveWatch/Sources Shared -name '*.swift')
echo "✓ watchOS OK"
