#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/heartdrive-link.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
swiftc Shared/WatchMessages.swift Shared/HeartRateLink.swift \
  HeartDrive/Sources/HeartRate/HeartRateHub.swift \
  Tools/LinkSim/*.swift -o "$BUILD/link-tests"
"$BUILD/link-tests"
