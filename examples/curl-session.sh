#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8100}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.apple.Preferences}"

curl -sS "$BASE_URL/status"
printf '\n'

SESSION_RESPONSE="$(
  curl -sS \
    -H 'Content-Type: application/json' \
    -d "{\"capabilities\":{\"alwaysMatch\":{\"bundleId\":\"$APP_BUNDLE_ID\"}}}" \
    "$BASE_URL/session"
)"

printf '%s\n' "$SESSION_RESPONSE"

SESSION_ID="$(printf '%s' "$SESSION_RESPONSE" | ruby -rjson -e 'payload = JSON.parse(STDIN.read); puts(payload["sessionId"] || payload.dig("value", "sessionId") || "")')"

if [ -n "$SESSION_ID" ]; then
  curl -sS "$BASE_URL/session/$SESSION_ID/window/rect"
  printf '\n'
  curl -sS -X DELETE "$BASE_URL/session/$SESSION_ID"
  printf '\n'
fi
