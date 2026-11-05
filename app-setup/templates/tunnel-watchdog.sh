#!/usr/bin/env bash
#
# tunnel-watchdog: emails when the tunnel for __EXTERNAL_HOSTNAME__ is down.
# See docs/apps/cloudflare-tunnel-README.md.

# Usage: tunnel-watchdog [--check]
# --check prints the result only (no email, no state change). Exit 0 ready,
# 1 not ready.

# /ready: 200 while an edge connection is up, 503 if none. No answer means
# the daemon is not running.

# Placeholders are filled in by tunnel-watchdog-setup.sh.
# The LaunchAgent runs /bin/bash 3.2: no bash 4 features.

# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-11-05

set -euo pipefail

# launchd's PATH has no Homebrew. See docs/apps/monitoring-README.md.
ARCH="$(arch)"
case "${ARCH}" in
  arm64) HOMEBREW_PREFIX="/opt/homebrew" ;;
  *) HOMEBREW_PREFIX="/usr/local" ;;
esac
export PATH="${HOMEBREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOSTNAME_LABEL="__HOSTNAME__"
export MONITORING_EMAIL="__MONITORING_EMAIL__" # read by alert-lib.sh
APP_DOMAIN="__EXTERNAL_HOSTNAME__"
# cloudflared --metrics address, set by cloudflared-setup.sh (same
# TUNNEL_METRICS_PORT). Loopback only.
READY_URL="http://127.0.0.1:__TUNNEL_METRICS_PORT__/ready"

CONFIG_DIR="${HOME}/.config/tunnel-watchdog"
export STATE_FILE="${CONFIG_DIR}/state.json" # read by alert-lib.sh
LOG_FILE="${HOME}/.local/state/tunnel-watchdog.log"
ALERT_LIB="${ALERT_LIB:-${HOME}/.local/lib/alert-lib.sh}"

# Every 60 s: 3 failures alert after about 3 minutes, past any reconnect
# or daemon restart.
FAILURE_THRESHOLD=3
HEARTBEAT_INTERVAL_SECONDS=3600
# alert_transition resends an open alert every 12 hours.
export ALERT_REMINDER_SECONDS=43200

CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=10

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [tunnel-watchdog] %s\n' "${timestamp}" "$1" >>"${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Shared alert library: alert_send, alert_transition and the alert_state_*
# helpers on STATE_FILE. Deployed by tunnel-watchdog-setup.sh.
# ---------------------------------------------------------------------------

if [[ ! -r "${ALERT_LIB}" ]]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  log "ERROR: alert library not found at ${ALERT_LIB} — cannot send alerts. Re-run tunnel-watchdog-setup.sh"
  exit 1
fi
# shellcheck source=/dev/null
source "${ALERT_LIB}"

# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

# probe_ready BODY_FILE: sets PROBE_STATUS to "ready" or "down", and
# PROBE_DETAIL to a one-line description. Never fails.
probe_ready() {
  local body_file="$1" code="" rc=0
  code=$(curl -sS \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    -o "${body_file}" \
    -w '%{http_code}' \
    "${READY_URL}" 2>/dev/null) || rc=$?

  local conns
  conns=$(jq -r '.readyConnections // empty' "${body_file}" 2>/dev/null) || conns=""
  [[ "${conns}" =~ ^[0-9]+$ ]] || conns=""

  if [[ ${rc} -ne 0 ]]; then
    PROBE_STATUS=down
    PROBE_DETAIL="no answer from ${READY_URL} (curl exit ${rc}); cloudflared is probably not running"
  elif [[ "${code}" != "200" ]]; then
    PROBE_STATUS=down
    PROBE_DETAIL="${READY_URL} returned HTTP ${code:-000}${conns:+ with ${conns} ready connections}; cloudflared has no connection to Cloudflare"
  else
    PROBE_STATUS=ready
    PROBE_DETAIL="tunnel ready, ${conns:-unknown} connections to Cloudflare"
  fi
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

# Set one top-level state key to a JSON value.
state_set() {
  local state
  state=$(alert_state_read)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"${state}" || state='{}'
  state=$(jq --arg k "$1" --argjson v "$2" '.[$k] = $v' <<<"${state}")
  alert_state_write "${state}"
}

maybe_heartbeat() {
  local now last
  now=$(date +%s)
  last=$(alert_state_get last_ok_log 0)
  [[ "${last}" =~ ^[0-9]+$ ]] || last=0
  if [[ $((now - last)) -ge ${HEARTBEAT_INTERVAL_SECONDS} ]]; then
    log "OK: ${PROBE_DETAIL}"
    state_set last_ok_log "${now}"
  fi
}

# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

main() {
  local check_only=false
  if [[ "${1:-}" == "--check" ]]; then
    check_only=true
  elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--check]" >&2
    exit 64
  fi

  mkdir -p "${CONFIG_DIR}"
  mkdir -p "$(dirname "${LOG_FILE}")"

  # A global, not a local: the EXIT trap runs after main has returned.
  BODY_FILE=$(mktemp "${CONFIG_DIR}/ready.XXXXXX")
  trap 'rm -f "${BODY_FILE:-}"' EXIT

  PROBE_STATUS="" PROBE_DETAIL=""
  probe_ready "${BODY_FILE}"

  if [[ "${check_only}" == "true" ]]; then
    if [[ "${PROBE_STATUS}" == "ready" ]]; then
      echo "OK: ${PROBE_DETAIL}"
      exit 0
    fi
    echo "DOWN: ${PROBE_DETAIL}"
    exit 1
  fi

  local failures
  failures=$(alert_state_get failures 0)
  [[ "${failures}" =~ ^[0-9]+$ ]] || failures=0
  if [[ "${PROBE_STATUS}" == "ready" ]]; then
    if [[ ${failures} -gt 0 ]]; then
      log "OK again after ${failures} failed checks: ${PROBE_DETAIL}"
    fi
    failures=0
  else
    failures=$((failures + 1))
    log "WARNING: check failed (${failures}/${FAILURE_THRESHOLD}): ${PROBE_DETAIL}"
  fi
  state_set failures "${failures}"

  local is_bad=false
  [[ ${failures} -ge ${FAILURE_THRESHOLD} ]] && is_bad=true
  alert_transition "tunnel_down" "${is_bad}" \
    "[${HOSTNAME_LABEL}] Cloudflare Tunnel for ${APP_DOMAIN} is down" \
    "The Cloudflare Tunnel that serves ${APP_DOMAIN} has not been ready for
${failures} checks in a row (checked every minute). Until it recovers,
${APP_DOMAIN} shows a Cloudflare error page to every visitor. The LAN
address is not affected.

Last result: ${PROBE_DETAIL}

Check the daemon:
  sudo launchctl print system/com.__HOSTNAME_LOWER__.cloudflare-tunnel
  tail -50 ~__OPERATOR_USERNAME__/.local/state/cloudflared/cloudflared-error.log
Restart it:
  sudo launchctl kickstart -kp system/com.__HOSTNAME_LOWER__.cloudflare-tunnel

See docs/apps/cloudflare-tunnel-README.md in mac-server-setup.
Log: ${LOG_FILE}" \
    "RESOLVED: [${HOSTNAME_LABEL}] Cloudflare Tunnel for ${APP_DOMAIN} is ready again" \
    "The Cloudflare Tunnel for ${APP_DOMAIN} is ready again: ${PROBE_DETAIL}.
No action required." || true

  if [[ "${PROBE_STATUS}" == "ready" ]]; then
    maybe_heartbeat
  fi
}

# Entry point — skipped when sourced for tests (TEST_RUNNER=true)
if [[ "${TEST_RUNNER:-false}" != "true" ]]; then
  main "$@"
fi
