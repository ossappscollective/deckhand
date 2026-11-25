#!/usr/bin/env bash
# Submits a .zip / .dmg / .pkg to Apple's notary service and waits for the verdict.
# Credentials come from the environment, either
#   an App Store Connect API key: APPLE_API_KEY (key id), APPLE_API_ISSUER, APPLE_API_KEY_PATH (the .p8 file), or
#   an Apple ID:                  APPLE_ID, APPLE_PASSWORD (app-specific), APPLE_TEAM_ID.
# The API key wins when both are set.
set -euo pipefail

file="${1:?usage: notarize.sh <file>}"

if [ -n "${APPLE_API_KEY:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ] && [ -f "${APPLE_API_KEY_PATH:-}" ]; then
  credentials=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER")
else
  : "${APPLE_ID:?}" "${APPLE_PASSWORD:?}" "${APPLE_TEAM_ID:?}"
  credentials=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD")
fi

result=$(xcrun notarytool submit "$file" "${credentials[@]}" --wait --timeout 30m --output-format json)
echo "$result"

status=$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
id=$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')

if [ "$status" != "Accepted" ]; then
  echo "::error::Notarization of $(basename "$file") finished with status '$status'"
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" "${credentials[@]}" || true
  fi
  exit 1
fi
echo "Notarized $(basename "$file")"
