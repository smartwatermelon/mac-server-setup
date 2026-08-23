# shellcheck shell=bash
#
# pia-port-guard.sh — validate a PIA forwarded port before applying it
#
# This is a sourced library, not an executable script; it defines functions and
# runs nothing on its own.
#
# The upstream haugene/transmission-openvpn image ships an update-port.sh whose
# error handling makes a bad situation worse. When getSignature fails it logs
# "the has been a fatal_error" and then carries on regardless, leaving $pf_port
# empty. The empty value flows into:
#
#     transmission-remote "$HOST" -p ""
#
# which sets Transmission's listen port to 0. With no peer port, tracker
# announces fail and magnet links cannot retrieve metadata over DHT, so
# downloads stop entirely rather than merely running unforwarded. The script
# then prints "SUCCESS" with a blank "Port:" line, so the logs claim everything
# is fine. Observed in production 2026-08-21 through 2026-08-23 (issue #159).
#
# This guard is the missing validation. Source it and call apply_port to make
# the empty-port case a no-op that preserves whatever port Transmission is
# already using.
#
# Usage (from a patched update-port.sh):
#     source /etc/openvpn/pia/pia-port-guard.sh
#     apply_port "$pf_port" "$TRANSMISSION_HOST" "${myauth_array[@]}"
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-08-23

# Valid TCP/UDP port for peer traffic. Ports below 1024 are privileged and PIA
# never assigns them, so anything in that range signals a malformed response.
#
# Deliberately not `readonly`: update-port.sh runs an infinite retry loop and
# may source this file more than once, which would abort under `set -e` if
# these were immutable.
PIA_GUARD_PORT_MIN=1024
PIA_GUARD_PORT_MAX=65535

guard_log() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s %s\n' "${now}" "$*"
}

# Return 0 only for a value that is safe to hand to transmission-remote -p.
#
# Rejects: empty strings, whitespace, non-numeric values, the literal "null"
# that jq emits for a missing field, and out-of-range numbers.
is_valid_port() {
  local port="${1:-}"

  [[ -n "${port}" ]] || return 1
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1

  # Guard against values like 00080 that are numeric but not a real port, and
  # against anything outside the unprivileged range.
  [[ "${port}" -ge "${PIA_GUARD_PORT_MIN}" ]] || return 1
  [[ "${port}" -le "${PIA_GUARD_PORT_MAX}" ]] || return 1

  return 0
}

# Read the port Transmission is currently listening on, or empty if it cannot
# be determined. Used to decide whether an update is actually needed.
# Auth is passed as zero or more separate arguments ("--auth" "user:pass")
# rather than one pre-joined string, so no word splitting is required.
current_peer_port() {
  local host="$1"
  shift
  local auth=("$@")

  local session_info
  session_info="$(transmission-remote "${host}" "${auth[@]}" -si 2>/dev/null || true)"

  local listen_line
  listen_line="$(grep -iE 'Listen ?port' <<<"${session_info}" || true)"

  local digits
  digits="$(grep -oE '[0-9]+' <<<"${listen_line}" || true)"

  head -1 <<<"${digits}"
}

# Apply a forwarded port to Transmission, refusing to apply an invalid one.
#
# Returns 0 when the port was applied or was already correct, 1 when the port
# was rejected. A rejection deliberately leaves Transmission untouched: running
# unforwarded on a stale-but-valid port is far better than running with port 0.
apply_port() {
  local new_port="${1:-}"
  local host="$2"
  shift 2
  local auth=("$@")

  if ! is_valid_port "${new_port}"; then
    local existing
    existing="$(current_peer_port "${host}" "${auth[@]}")"

    guard_log "REFUSING to apply invalid port forwarding result: '${new_port}'"
    guard_log "  Port forwarding is unavailable; Transmission left unchanged."
    if [[ -n "${existing}" && "${existing}" != "0" ]]; then
      guard_log "  Keeping existing peer port ${existing} (unforwarded)."
    else
      guard_log "  WARNING: Transmission has no valid peer port (currently ${existing:-unknown})."
      guard_log "  Magnet links will not resolve until a peer port is set."
    fi
    return 1
  fi

  local existing
  existing="$(current_peer_port "${host}" "${auth[@]}")"

  if [[ "${existing}" == "${new_port}" ]]; then
    guard_log "Peer port already ${new_port}; no change needed."
    return 0
  fi

  guard_log "Setting Transmission peer port to ${new_port}"
  transmission-remote "${host}" "${auth[@]}" -p "${new_port}"
}
