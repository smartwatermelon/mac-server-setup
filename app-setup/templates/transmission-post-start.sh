#!/usr/bin/env bash
#
# transmission-post-start.sh — PIA port forwarding with validation
#
# Replaces the port updater bundled in haugene/transmission-openvpn. The
# container runs this automatically after Transmission starts, provided
# DISABLE_PORT_UPDATER=true is set so the bundled updater stays out of the way.
#
# Why replace it rather than patch it: the bundled script lives at
# /etc/openvpn/pia/update-port.sh inside the image, alongside the 167 .ovpn
# region configs. Mounting over that directory to swap one file would hide the
# configs and break region selection, and editing a file inside a running
# container does not survive a recreate. /scripts is already bind-mounted and
# the image documents /scripts/transmission-post-start.sh as a hook, so owning
# the whole loop from here is both simpler and durable across image updates.
#
# The bug this exists to prevent (issue #159): on a getSignature failure the
# bundled script logs a fatal error, carries on with an empty $pf_port, and
# runs `transmission-remote -p ""`. That sets the listen port to 0, which stops
# tracker announces and leaves magnet links unable to fetch metadata over DHT —
# downloads stop entirely rather than merely running unforwarded. It then logs
# "SUCCESS" with a blank port. Observed in production 2026-08-21 → 08-23.
#
# This version refuses to apply a port it cannot validate, leaving whatever
# Transmission is already using in place.
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-08-23

set -uo pipefail

# Deliberately not `set -e`: this runs for the container's lifetime and a
# transient curl failure must not kill the loop. Failures are handled where
# they occur.

# The image calls this hook SYNCHRONOUSLY:
#
#     /scripts/transmission-post-start.sh "${USER_SCRIPT_ARGS[@]}"
#
# with no trailing `&` — unlike the bundled updater, which it backgrounds
# itself. Since this script runs a lifetime loop, returning control is our
# responsibility: blocking here hangs the rest of the container's startup
# chain, leaving the tunnel negotiated but passing no traffic at all.
#
# So re-exec ourselves detached and return immediately. PIA_PORT_DETACHED marks
# the background copy so it does not fork again.
# Output stays attached to the container log (fd 1/2 of PID 1) — discarding it
# would leave an operator no way to see what the manager is doing.
if [[ -z "${PIA_PORT_DETACHED:-}" ]]; then
  PIA_PORT_DETACHED=1 setsid "$0" "$@" <&- &
  exit 0
fi

GUARD_LIB="/scripts/pia-port-guard.sh"

# PIA's next-generation port forwarding. 19999 is a convention from PIA's
# reference implementation, not a value they advertise — their server list
# publishes ports for every other service but none for forwarding. If PIA ever
# moves it, this fails closed: the guard keeps the existing port rather than
# zeroing it.
PIA_TOKEN_URL="https://www.privateinternetaccess.com/gtoken/generateToken"
PF_API_PORT=19999

CURL_MAX_TIME=15
CURL_RETRY=3
CURL_RETRY_DELAY=10

# How often to re-assert the reservation. PIA expires bindings that are not
# refreshed; upstream uses the same 15-minute cadence.
REFRESH_INTERVAL=900

# Renew the token when the reservation has less than a week left, matching
# upstream's threshold.
TOKEN_MIN_REMAINING=$((60 * 60 * 24 * 7))

log() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s [pia-port] %s\n' "${now}" "$*"
}

# ---------------------------------------------------------------------------
# Guard
# ---------------------------------------------------------------------------

if [[ ! -r "${GUARD_LIB}" ]]; then
  log "FATAL: guard library missing at ${GUARD_LIB}"
  log "Refusing to manage the peer port without validation — exiting."
  log "Transmission keeps its configured port and runs unforwarded."
  exit 1
fi

# shellcheck source=/dev/null
source "${GUARD_LIB}"

# ---------------------------------------------------------------------------
# Transmission connection details
# ---------------------------------------------------------------------------

TRANSMISSION_RPC_PORT="${TRANSMISSION_RPC_PORT:-9091}"
if [[ -z "${TRANSMISSION_RPC_URL:-}" ]] && [[ -r /etc/transmission/default-settings.json ]]; then
  TRANSMISSION_RPC_URL="$(jq -r '."rpc-url"' /etc/transmission/default-settings.json 2>/dev/null || echo /transmission/rpc)"
fi
TRANSMISSION_RPC_URL="${TRANSMISSION_RPC_URL:-/transmission/rpc}"

# Trailing slash breaks transmission-remote's URL parsing.
TRANSMISSION_HOST="http://localhost:${TRANSMISSION_RPC_PORT}${TRANSMISSION_RPC_URL%/}"

# Auth is assembled as an array so it expands to zero or two arguments without
# relying on word splitting.
TR_AUTH=()
TRANSMISSION_HOME="${TRANSMISSION_HOME:-/config/transmission-home}"
SETTINGS_FILE="${TRANSMISSION_HOME}/settings.json"
CREDS_FILE=/config/transmission-credentials.txt

if [[ -r "${SETTINGS_FILE}" ]] \
  && grep -q '"rpc-authentication-required"[[:space:]]*:[[:space:]]*true' "${SETTINGS_FILE}" 2>/dev/null; then
  if [[ -r "${CREDS_FILE}" ]]; then
    tr_user="$(head -1 "${CREDS_FILE}")"
    tr_pass="$(tail -1 "${CREDS_FILE}")"
    TR_AUTH=(--auth "${tr_user}:${tr_pass}")
    log "Transmission RPC authentication enabled"
  else
    log "WARNING: RPC auth required but ${CREDS_FILE} is unreadable"
  fi
fi

# ---------------------------------------------------------------------------
# PIA credentials
# ---------------------------------------------------------------------------

PIA_CREDS_FILE=/config/openvpn-credentials.txt
if [[ ! -r "${PIA_CREDS_FILE}" ]]; then
  log "FATAL: PIA credentials not readable at ${PIA_CREDS_FILE}"
  exit 1
fi
pia_user="$(sed -n 1p "${PIA_CREDS_FILE}")"
pia_pass="$(sed -n 2p "${PIA_CREDS_FILE}")"

# ---------------------------------------------------------------------------
# PIA port forwarding API
# ---------------------------------------------------------------------------

# Gateway that terminates the tunnel; the PF service answers here.
pf_gateway() {
  ip route 2>/dev/null | grep tun | grep -v src | head -1 | awk '{print $3}'
}

# Same value, but safe to interpolate into a log line before the tunnel is up.
pf_gateway_or_unknown() {
  local gateway
  gateway="$(pf_gateway)"
  printf '%s' "${gateway:-not yet established}"
}

# Populates pf_token. Returns non-zero if PIA would not issue one.
get_auth_token() {
  local response
  response="$(curl --silent --show-error --request POST \
    --max-time "${CURL_MAX_TIME}" \
    --user "${pia_user}:${pia_pass}" \
    "${PIA_TOKEN_URL}" 2>/dev/null)" || {
    log "Token request failed (network or auth)"
    return 1
  }

  pf_token="$(jq -r '.token // empty' <<<"${response}" 2>/dev/null)"
  [[ -n "${pf_token}" ]] || {
    log "Token response contained no token"
    return 1
  }
}

# Populates pf_payload, pf_signature, pf_port, pf_token_expiry.
#
# The PF endpoint presents a certificate for a PIA hostname while we reach it
# by gateway IP, so --insecure is required; the bearer token is what actually
# authenticates the call.
get_signature() {
  local gateway response status
  gateway="$(pf_gateway)"
  [[ -n "${gateway}" ]] || {
    log "No tunnel gateway — is the VPN up?"
    return 1
  }

  response="$(curl --insecure --get --silent --show-error \
    --retry "${CURL_RETRY}" --retry-delay "${CURL_RETRY_DELAY}" \
    --max-time "${CURL_MAX_TIME}" \
    --data-urlencode "token=${pf_token}" \
    "https://${gateway}:${PF_API_PORT}/getSignature" 2>/dev/null)" || {
    log "getSignature unreachable at ${gateway}:${PF_API_PORT}"
    return 1
  }

  status="$(jq -r '.status // "unparseable"' <<<"${response}" 2>/dev/null)"
  if [[ "${status}" != "OK" ]]; then
    log "getSignature returned status '${status}' — region may not offer port forwarding"
    return 1
  fi

  pf_payload="$(jq -r '.payload // empty' <<<"${response}" 2>/dev/null)"
  pf_signature="$(jq -r '.signature // empty' <<<"${response}" 2>/dev/null)"
  [[ -n "${pf_payload}" && -n "${pf_signature}" ]] || {
    log "getSignature response missing payload or signature"
    return 1
  }

  local decoded
  decoded="$(base64 -d <<<"${pf_payload}" 2>/dev/null)" || {
    log "Could not decode payload"
    return 1
  }

  pf_port="$(jq -r '.port // empty' <<<"${decoded}" 2>/dev/null)"
  local expiry_raw
  expiry_raw="$(jq -r '.expires_at // empty' <<<"${decoded}" 2>/dev/null)"
  # GNU date only: --date is rejected by BSD/macOS date. This script always runs
  # inside the Linux container, so that is correct here — but anyone sourcing it
  # on macOS (a future BATS test exercising get_signature, say) gets expiry 0
  # from the fallback, which forces a full token renewal every cycle instead of
  # a cheap re-bind. Degraded but safe, and silent, so it is worth knowing.
  pf_token_expiry="$(date --date="${expiry_raw}" +%s 2>/dev/null || echo 0)"
}

# Reserves (or re-asserts) the port PIA assigned. Must be repeated periodically
# or PIA drops the binding.
bind_port() {
  local gateway response status
  gateway="$(pf_gateway)"
  [[ -n "${gateway}" ]] || return 1

  response="$(curl --insecure --get --silent --show-error \
    --retry "${CURL_RETRY}" --retry-delay "${CURL_RETRY_DELAY}" \
    --max-time "${CURL_MAX_TIME}" \
    --data-urlencode "payload=${pf_payload}" \
    --data-urlencode "signature=${pf_signature}" \
    "https://${gateway}:${PF_API_PORT}/bindPort" 2>/dev/null)" || {
    log "bindPort unreachable"
    return 1
  }

  status="$(jq -r '.status // "unparseable"' <<<"${response}" 2>/dev/null)"
  [[ "${status}" == "OK" ]] || {
    log "bindPort returned status '${status}'"
    return 1
  }
}

# Full acquisition: token, signature, reservation, then hand the port to the
# guard. Returns non-zero if any step fails, leaving the peer port untouched.
acquire_and_apply() {
  get_auth_token || return 1
  get_signature || return 1
  bind_port || return 1

  # apply_port refuses anything that isn't a valid port, so a malformed
  # response can never reach transmission-remote.
  apply_port "${pf_port}" "${TRANSMISSION_HOST}" "${TR_AUTH[@]}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

pf_token=""
pf_payload=""
pf_signature=""
pf_port=""
pf_token_expiry=0

# The image invokes this hook from /etc/transmission/start.sh without exporting
# the container environment, so OPENVPN_CONFIG (and every other `podman run -e`
# variable) is absent here — a previous version of this line logged
# "region: unknown" on every start and cost real debugging time during the
# 2026-08-23 incident by looking like a misconfiguration (issue #182).
#
# The tunnel gateway is derived from the routing table rather than the
# environment, so it is always available, and it is the more useful value: it
# is the endpoint the port-forwarding API is queried against, and it reflects
# what actually connected rather than what was requested.
startup_gateway="$(pf_gateway_or_unknown)"
log "Starting PIA port forwarding manager (tunnel gateway: ${startup_gateway})"

# Transmission has to be accepting RPC before a port can be set.
until transmission-remote "${TRANSMISSION_HOST}" "${TR_AUTH[@]}" -si >/dev/null 2>&1; do
  log "Waiting for Transmission RPC..."
  sleep 10
done
log "Transmission is responsive"

if acquire_and_apply; then
  log "Port forwarding active on ${pf_port}"
else
  log "Could not obtain a forwarded port — continuing unforwarded."
  log "Transmission keeps its existing peer port; downloads still work, but"
  log "inbound peer connections will not."
fi

while true; do
  sleep "${REFRESH_INTERVAL}" &
  wait $!

  now="$(date +%s)"
  remaining=$((pf_token_expiry - now))

  if [[ -z "${pf_payload}" ]] || [[ ${remaining} -lt ${TOKEN_MIN_REMAINING} ]]; then
    # No active reservation, or the current one is close to expiry.
    if [[ -n "${pf_payload}" ]]; then
      log "Reservation expiring in $((remaining / 86400))d — renewing"
    fi
    if acquire_and_apply; then
      log "Port forwarding renewed on ${pf_port}"
    else
      log "Renewal failed; will retry in $((REFRESH_INTERVAL / 60)) minutes"
    fi
    continue
  fi

  # Re-assert the existing reservation so PIA does not drop it.
  if ! bind_port; then
    log "Re-bind failed; will attempt a full renewal next cycle"
    pf_payload=""
  fi
done
