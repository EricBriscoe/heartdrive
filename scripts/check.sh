#!/bin/bash
# Fast local gate; --analyze also builds both targets for reference analysis.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ($# -eq 1 && "$1" != --analyze) ]]; then
  echo 'Usage: scripts/check.sh [--analyze]' >&2
  exit 2
fi
bash scripts/test-control.sh
bash scripts/test-core.sh
bash scripts/test-link.sh
zsh scripts/typecheck.sh
swiftlint lint --strict --quiet
if [[ "${1:-}" == --analyze ]]; then
  xcodegen generate
  periphery scan --strict -- -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
  REPORT=$(mktemp -d "${TMPDIR:-/tmp}/heartdrive-clones.XXXXXX")
  npx --yes jscpd@4.0.8 --config .jscpd.json --output "$REPORT"
  echo "Clone report (review candidates, not automatic deletions): $REPORT"
fi
