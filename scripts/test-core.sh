#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/heartdrive-core.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
swiftc Shared/WatchMessages.swift Shared/HeartRateLink.swift \
  HeartDrive/Sources/HeartRate/HeartRateHub.swift HeartDrive/Sources/Bluetooth/FTMS.swift \
  Tools/CoreTests/main.swift -o "$BUILD/core-tests"
"$BUILD/core-tests"
