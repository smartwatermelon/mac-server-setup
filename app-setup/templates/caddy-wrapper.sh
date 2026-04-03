#!/usr/bin/env bash
# caddy-wrapper.sh — reads CF_API_TOKEN from System keychain, then exec's Caddy.
# Run as root via LaunchDaemon. The token never appears in the plist or on disk.
set -euo pipefail

CF_API_TOKEN=$(security find-generic-password \
  -s "cloudflare-api-token" \
  -a "__EXTERNAL_HOSTNAME__" \
  -w \
  /Library/Keychains/System.keychain) || {
  echo "ERROR: cloudflare-api-token not found in System keychain" >&2
  exit 1
}
export CF_API_TOKEN

exec /opt/homebrew/bin/caddy run \
  --config /Users/__OPERATOR_USERNAME__/.config/caddy/Caddyfile \
  --adapter caddyfile
