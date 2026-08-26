#!/usr/bin/env bash
#
# pia-port-watchdog.sh — alert when PIA port forwarding is lost
#
# Port-forwarding loss is invisible to anything that watches download activity,
# because downloads keep working without it. Transmission still connects
# outbound to peers that accept inbound connections, so well-seeded torrents
# proceed — slower, and only to the reachable subset of the swarm.
#
# What actually breaks is quieter: with no peer port, tracker announces fail and
# magnet links cannot retrieve metadata over DHT, so *newly added* torrents never
# start. Existing ones look fine. Port forwarding was dead from 2026-08-21
# through 08-23 — about 47 hours — and was only noticed when a freshly added
# magnet sat at 0% and someone went looking (issue #181).
#
# The port guard added in #180 stops a PF failure from zeroing the peer port,
# which is what turned that outage from "degraded" into "downloads stopped".
# It deliberately fails soft: on PF failure it keeps the existing port and
# carries on unforwarded. That is the right behaviour, and it means the system
# now degrades silently. This watchdog is the missing signal.
#
# Each invocation is a single poll cycle: fetch, compare, alert, exit — the
# same shape as plex-watchdog.sh, driven by a LaunchAgent.
#
# Template placeholders (replaced by podman-transmission-setup.sh at deploy time):
#   __SERVER_NAME__              → server hostname for logging (e.g. TILSIT)
#   __MONITORING_EMAIL__         → destination email address
#   __TRANSMISSION_HOST_PORT__   → Transmission RPC port (e.g. 9091)
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-08-24

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SERVER_NAME="__SERVER_NAME__"
MONITORING_EMAIL="__MONITORING_EMAIL__"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"

TRANSMISSION_RPC_URL="http://localhost:__TRANSMISSION_HOST_PORT__/transmission/rpc"

STATE_DIR="${HOME}/.config/pia-port-watchdog"
STATE_FILE="${STATE_DIR}/state.json"
MSMTP_CONFIG="${HOME}/.config/msmtp/config"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-pia-port-watchdog.log"

# The peer port legitimately reads 0 for a few seconds during a container
# restart or a region change. Require several consecutive bad polls before
# alerting so a routine restart does not page anyone.
CONSECUTIVE_FAILURE_THRESHOLD=3

# Log that everything is fine once an hour rather than every cycle, matching
# plex-watchdog's drift-vs-heartbeat cadence.
HEARTBEAT_INTERVAL_SECONDS=3600

CURL_MAX_TIME=15

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [pia-port-watchdog] %s\n' "${timestamp}" "$1" >>"${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# State (atomic write via temp+mv, as plex-watchdog does)
# ---------------------------------------------------------------------------

read_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    cat "${STATE_FILE}"
  else
    echo '{}'
  fi
}

write_state() {
  local state="$1"
  local tmp="${STATE_FILE}.tmp.$$"
  printf '%s\n' "${state}" >"${tmp}"
  mv "${tmp}" "${STATE_FILE}"
}

state_get() {
  local key="$1"
  local default="${2:-}"
  local val
  val=$(read_state | jq -r ".${key} // empty" 2>/dev/null) || true
  printf '%s' "${val:-${default}}"
}

# ---------------------------------------------------------------------------
# Transmission RPC
#
# RPC auth is disabled on localhost (TRANSMISSION_RPC_AUTHENTICATION_REQUIRED
# is false), so no credentials are needed. Transmission answers the first
# request with 409 and a CSRF token, which every later request must echo back —
# the same handshake pending-move-cleanup.sh performs.
# ---------------------------------------------------------------------------

rpc_session_id() {
  curl -s -D - --max-time "${CURL_MAX_TIME}" "${TRANSMISSION_RPC_URL}" 2>/dev/null \
    | awk 'tolower($0) ~ /^x-transmission-session-id:/{gsub(/\r/,""); print $2; exit}'
}

# Print the configured peer port, or nothing if the RPC could not be read.
# Returns non-zero when Transmission is unreachable, which is deliberately
# distinct from "reachable and reporting port 0".
peer_port() {
  local session_id
  session_id="$(rpc_session_id)"
  [[ -n "${session_id}" ]] || return 1

  local response
  response="$(curl -s --max-time "${CURL_MAX_TIME}" "${TRANSMISSION_RPC_URL}" \
    -H "X-Transmission-Session-Id: ${session_id}" \
    --data-raw '{"method":"session-get","arguments":{"fields":["peer-port"]}}' \
    2>/dev/null)" || return 1

  [[ "${response}" == *'"result":"success"'* ]] || return 1

  local port
  port="$(jq -r '.arguments["peer-port"] // empty' <<<"${response}" 2>/dev/null)" || return 1
  [[ -n "${port}" ]] || return 1

  printf '%s' "${port}"
}

# Ask Transmission whether its peer port is actually reachable from outside.
# Prints "yes", "no", or "unknown" — a non-zero port can still be unforwarded,
# which is exactly the state that went unnoticed for 47 hours.
port_is_open() {
  local session_id
  session_id="$(rpc_session_id)"
  [[ -n "${session_id}" ]] || {
    printf 'unknown'
    return 0
  }

  local response
  response="$(curl -s --max-time "${CURL_MAX_TIME}" "${TRANSMISSION_RPC_URL}" \
    -H "X-Transmission-Session-Id: ${session_id}" \
    --data-raw '{"method":"port-test"}' 2>/dev/null)" || {
    printf 'unknown'
    return 0
  }

  # NOT `// "unknown"`. jq's alternative operator fires on false as well as
  # null, so `.arguments["port-is-open"] // "unknown"` turns a genuine
  # "port is closed" into "unknown" — silently discarding the single most
  # important reading this watchdog takes. Test for presence explicitly.
  local raw
  raw="$(jq -r 'if has("arguments") and (.arguments | has("port-is-open"))
                then .arguments["port-is-open"] | tostring
                else "unknown" end' <<<"${response}" 2>/dev/null)" || {
    printf 'unknown'
    return 0
  }

  case "${raw}" in
    true) printf 'yes' ;;
    false) printf 'no' ;;
    *) printf 'unknown' ;;
  esac
}

# ---------------------------------------------------------------------------
# Email
# ---------------------------------------------------------------------------

send_email() {
  local subject="$1"
  local body="$2"

  if [[ ! -f "${MSMTP_CONFIG}" ]]; then
    log "ERROR: msmtp config not found at ${MSMTP_CONFIG} — cannot send email"
    return 1
  fi

  printf 'Subject: %s\nTo: %s\n\n%s\n' "${subject}" "${MONITORING_EMAIL}" "${body}" \
    | msmtp -C "${MSMTP_CONFIG}" "${MONITORING_EMAIL}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------

# Logs a heartbeat if one is due, and prints the timestamp the caller should
# persist: the new one when it logged, the existing one otherwise.
#
# This deliberately does not write state itself. It used to, which meant the
# healthy path wrote the state file twice per cycle — once here with a fresh
# last_heartbeat but every other field stale from the previous cycle, then
# again in main with the real values. Each write is atomic on its own, so the
# file was never torn, but a kill landing between them left a state file
# pairing a current heartbeat with last cycle's port and failure count. Main
# then had to read its own heartbeat back off disk to carry it forward.
#
# Returning the value instead collapses that to a single write at the end of
# the cycle, so state advances all at once or not at all.
maybe_heartbeat() {
  local detail="$1"
  local current="$2"

  local now_epoch last_epoch
  now_epoch=$(date +%s)
  last_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "${current}" '+%s' 2>/dev/null) || last_epoch=0

  if [[ $((now_epoch - last_epoch)) -ge ${HEARTBEAT_INTERVAL_SECONDS} ]]; then
    log "OK: ${detail}"
    # Assign first, then print through the same printf the suppressed branch
    # uses, so both return paths have one visible output contract. Command
    # substitution strips the trailing newline either way, so this changes
    # nothing a caller can observe -- but a reader no longer has to work that
    # out to be sure. Assigning separately also keeps date's exit status
    # visible instead of burying it inside printf's arguments.
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s' "${now}"
    return 0
  fi

  # Suppressed, not failed: carrying the existing timestamp forward is the
  # normal outcome for all but one cycle an hour. Return explicitly so the
  # status is the function's own contract rather than whatever printf last
  # happened to return.
  printf '%s' "${current}"
  return 0
}

# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

main() {
  mkdir -p "${STATE_DIR}"
  mkdir -p "$(dirname "${LOG_FILE}")"

  local was_alerted failures
  was_alerted=$(state_get "alerted" "false")
  failures=$(state_get "consecutive_failures" "0")

  # An unreachable Transmission is a different problem with its own monitoring
  # (the container health check restarts it). Reporting it as lost port
  # forwarding would be wrong, and counting it toward the failure streak would
  # eventually alert for the wrong reason. Leave the streak untouched.
  local port
  if ! port="$(peer_port)"; then
    log "Transmission RPC unreachable — skipping this cycle"
    exit 0
  fi

  local open
  open="$(port_is_open)"

  # Two independent symptoms of the same loss. A zero port means the peer port
  # was never set or was zeroed; "no" means it is set but nothing outside can
  # reach it. Either one stops new torrents from starting.
  local bad=false
  local reason=""
  if [[ "${port}" == "0" ]]; then
    bad=true
    reason="Transmission's peer port is 0 — no port is set at all."
  elif [[ "${open}" == "no" ]]; then
    bad=true
    reason="Peer port ${port} is set but is not reachable from outside."
  fi

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Read the existing heartbeat once, here. maybe_heartbeat either hands it
  # back unchanged or returns a fresh one; either way the single write at the
  # end of this function persists whatever it returned.
  local heartbeat
  heartbeat="$(state_get "last_heartbeat" "1970-01-01T00:00:00Z")"

  if [[ "${bad}" == "true" ]]; then
    failures=$((failures + 1))
    log "Port forwarding looks lost (${failures}/${CONSECUTIVE_FAILURE_THRESHOLD}): ${reason}"

    # Alert on the transition into the bad state, not once per cycle. A 47-hour
    # outage at a 15-minute cadence would otherwise be ~190 identical emails.
    if [[ ${failures} -ge ${CONSECUTIVE_FAILURE_THRESHOLD} ]] && [[ "${was_alerted}" != "true" ]]; then
      log "ALERT: port forwarding lost — notifying ${MONITORING_EMAIL}"
      if send_email \
        "[${SERVER_NAME}] Transmission port forwarding lost" \
        "PIA port forwarding appears to be lost on ${SERVER_NAME}.

${reason}

  Peer port:     ${port}
  Port is open:  ${open}

Downloads already in progress will continue, more slowly. Newly added
torrents will not start: with no reachable peer port, tracker announces fail
and magnet links cannot fetch metadata over DHT. That is why this fails
quietly and needs an alert at all.

To investigate:
  ssh operator@${HOSTNAME_LOWER} podman logs --tail 100 transmission-vpn | grep pia-port

The port forwarding manager logs its own outcome there. 'REFUSING to apply
invalid port forwarding result' means PIA declined to issue a port; the
existing port was deliberately kept rather than zeroed.

If the region stopped serving port forwarding, survey the alternatives:
  ssh operator@${HOSTNAME_LOWER} ~/containers/transmission/scripts/pia-pf-probe.sh --all"; then
        was_alerted=true
      else
        log "ERROR: failed to send alert email"
      fi
    fi
  else
    # Recovered: tell whoever got the alert, then reset so the next loss alerts
    # again.
    if [[ "${was_alerted}" == "true" ]]; then
      log "RESOLVED: port forwarding restored on port ${port}"
      send_email \
        "[${SERVER_NAME}] Transmission port forwarding restored" \
        "Port forwarding is working again on ${SERVER_NAME}.

  Peer port:     ${port}
  Port is open:  ${open}

No action required." || true
    fi
    was_alerted=false
    failures=0
    heartbeat="$(maybe_heartbeat "peer port ${port}, reachable: ${open}" "${heartbeat}")"
  fi

  local new_state
  new_state=$(jq -n \
    --arg lp "${now}" \
    --arg lh "${heartbeat}" \
    --arg pt "${port}" \
    --arg po "${open}" \
    --argjson cf "${failures}" \
    --argjson al "${was_alerted}" \
    '{
      last_poll: $lp,
      last_heartbeat: $lh,
      peer_port: $pt,
      port_is_open: $po,
      consecutive_failures: $cf,
      alerted: $al
    }')

  write_state "${new_state}"
}

# Entry point — skipped when sourced for tests (TEST_RUNNER=true)
if [[ "${TEST_RUNNER:-false}" != "true" ]]; then
  main "$@"
fi
