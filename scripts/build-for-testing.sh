#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DESTINATION="${DESTINATION:-generic/platform=iOS}"
SCHEME="${SCHEME:-WebDriverAgentRunner}"
PROJECT="${PROJECT:-WebDriverAgent.xcodeproj}"

args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination "$DESTINATION"
)

if [ -n "${SIGNING_CONFIG:-}" ]; then
  args+=(-xcconfig "$SIGNING_CONFIG")
else
  args+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${args[@]}" build-for-testing
