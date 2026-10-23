#!/usr/bin/env bash
#
# cloudflared-wrapper.sh: System keychain token → TUNNEL_TOKEN, then exec
# cloudflared. Run as root by the LaunchDaemon.

# Never in a plist or on a command line, so never `service install <token>`.
# See docs/apps/cloudflare-tunnel-README.md.

# Placeholders are filled in by cloudflared-setup.sh.

set -euo pipefail

KEYCHAIN="/Library/Keychains/System.keychain"
KEYCHAIN_SERVICE="cloudflare-tunnel-token"
KEYCHAIN_ACCOUNT="__EXTERNAL_HOSTNAME__"
METRICS_ADDRESS="127.0.0.1:__TUNNEL_METRICS_PORT__"
CLOUDFLARED_BIN="/opt/homebrew/bin/cloudflared"

read_tunnel_token() {
  /usr/bin/security find-generic-password \
    -s "${KEYCHAIN_SERVICE}" \
    -a "${KEYCHAIN_ACCOUNT}" \
    -w \
    "${KEYCHAIN}" 2>/dev/null
}

main() {
  local token
  token=$(read_tunnel_token) || token=""
  if [[ -z "${token}" ]]; then
    echo "ERROR: ${KEYCHAIN_SERVICE} (account ${KEYCHAIN_ACCOUNT}) not found in ${KEYCHAIN}" >&2
    exit 1
  fi
  if [[ ! -x "${CLOUDFLARED_BIN}" ]]; then
    echo "ERROR: cloudflared not found or not executable at ${CLOUDFLARED_BIN}" >&2
    exit 1
  fi

  TUNNEL_TOKEN="${token}"
  export TUNNEL_TOKEN
  unset token

  # --no-autoupdate: Homebrew owns the binary. The token comes from
  # TUNNEL_TOKEN, so `run` takes no argument.
  exec "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --metrics "${METRICS_ADDRESS}" run
}

# Entry point — skipped when sourced for tests (TEST_RUNNER=true)
if [[ "${TEST_RUNNER:-false}" != "true" ]]; then
  main "$@"
fi
