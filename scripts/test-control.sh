#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/heartdrive-control.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
swiftc HeartDrive/Sources/Control/ErgController.swift \
  HeartDrive/Sources/HeartRate/HeartRateHub.swift \
  HeartDrive/Sources/Models/RideSettings.swift \
  Tools/ControlTests/main.swift -o "$BUILD/tests"
"$BUILD/tests"
