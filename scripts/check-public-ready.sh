#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

blocked_terms=(
  "$(printf '\x45\x67\x65\x6d\x73\x6f\x66\x74')"
  "$(printf '\x65\x67\x65\x6d\x73\x6f\x66\x74')"
  "$(printf '\x74\x65\x73\x74\x63\x72\x69\x62\x65')"
  "$(printf '\x2f\x55\x73\x65\x72\x73\x2f\x65\x6d\x72\x65')"
  "$(printf '\x36\x51\x33\x34\x56\x37\x39\x4e\x57\x33')"
  "$(printf '\x4e\x45\x57\x5f\x57\x44\x41\x5f\x50\x52\x4f\x44')"
)

for term in "${blocked_terms[@]}"; do
  if rg -n --fixed-strings "$term" . \
    --glob '!scripts/check-public-ready.sh'; then
    echo "Blocked public-release term found: $term" >&2
    exit 1
  fi
done

plutil -lint IntegrationApp/Info.plist WebDriverAgentRunner/Info.plist >/dev/null
ruby -c tools/generate_project.rb >/dev/null
ruby -c tools/smoke_contract.rb >/dev/null
ruby -c tools/mjpeg_smoke.rb >/dev/null
ruby -c tools/stream_continuity_smoke.rb >/dev/null
xcodebuild -project WebDriverAgent.xcodeproj -list >/dev/null

echo "Public readiness checks passed."
