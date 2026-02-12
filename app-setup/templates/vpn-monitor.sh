#!/usr/bin/env bash
#
# vpn-monitor.sh - VPN state monitor for Transmission
#
# Monitors VPN tunnel interfaces (utun*) and manages Transmission accordingly:
# - VPN UP:      Ensures Transmission uses VPN IP as bind-address
# - VPN IP CHANGE: Updates bind-address to new VPN IP, restarts Transmission
# - VPN DROP:    Pauses all torrents, sets bind-address to 127.0.0.1
# - VPN RESTORE: Updates bind-address to new VPN IP, resumes torrents
#
# This script runs as a LaunchAgent under the operator user, alongside
# Transmission.app (GUI). It communicates with Transmission via RPC API
# for pause/resume and via defaults write for bind-address changes.
#
# Template placeholders (replaced during deployment):
# - __SERVER_NAME__: Server hostname for logging and RPC credentials
#
# Usage: Launched automatically by com.tilsit.vpn-monitor LaunchAgent
#   Not intended for manual execution.
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-12

set -euo pipefail

# Configuration (replaced during deployment)
SERVER_NAME="__SERVER_NAME__"

# Derived configuration
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
RPC_URL="http://localhost:19091/transmission/rpc"
RPC_USER="${HOSTNAME_LOWER}"
RPC_PASS="${HOSTNAME_LOWER}"
POLL_INTERVAL=5

# Logging configuration
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-vpn-monitor.log"
MAX_LOG_SIZE=5242880 # 5MB

# State tracking
LAST_VPN_IP=""
VPN_IS_DOWN=false
TORRENTS_PAUSED_BY_US=false

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Logging function
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [vpn-monitor] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

# Log rotation — called periodically from main loop
rotate_log() {
  if [[ -f "${LOG_FILE}" ]]; then
    local size
    size=$(stat -f%z "${LOG_FILE}" 2>/dev/null || echo "0")
    if [[ "${size}" -gt ${MAX_LOG_SIZE} ]]; then
      mv "${LOG_FILE}" "${LOG_FILE}.old"
      log "Log rotated (previous log exceeded ${MAX_LOG_SIZE} bytes)"
    fi
  fi
}

# Send desktop notification via terminal-notifier (if available)
notify() {
  local title="$1"
  local message="$2"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier \
      -title "${title}" \
      -message "${message}" \
      -group "vpn-monitor" \
      -sender "org.m0k.transmission" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# VPN Detection
# ---------------------------------------------------------------------------

# Get current VPN IP by scanning utun interfaces
# Returns the first non-loopback IPv4 address found on any utun interface
get_vpn_ip() {
  local ip

  # Scan utun0 through utun15 for an IPv4 address
  local i
  for i in $(seq 0 15); do
    ip=$(ifconfig "utun${i}" 2>/dev/null | awk '/inet / && !/127\./ {print $2}' | head -1)
    if [[ -n "${ip}" ]]; then
      echo "${ip}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Transmission RPC API
# ---------------------------------------------------------------------------

# Get a fresh X-Transmission-Session-Id header (required for all RPC calls).
# Transmission returns 409 with the session ID in the response headers.
# We use -si to include headers in output for reliable extraction.
get_session_id() {
  local response
  response=$(curl -si -u "${RPC_USER}:${RPC_PASS}" \
    --max-time 5 \
    "${RPC_URL}" 2>/dev/null || true)
  echo "${response}" | grep -o 'X-Transmission-Session-Id: [^ ]*' | head -1 | cut -d' ' -f2 | tr -d '[:space:]'
}

# Make an RPC call to Transmission
# Args: method [arguments_json]
rpc_call() {
  local method="$1"
  local arguments="${2:-{}}"

  local session_id
  session_id=$(get_session_id)

  if [[ -z "${session_id}" ]]; then
    log "ERROR: Cannot reach Transmission RPC - is Transmission running?"
    return 1
  fi

  # Build JSON payload using printf (callers must pass safe literal strings only)
  local payload
  payload=$(printf '{"method":"%s","arguments":%s}' "${method}" "${arguments}")

  curl -s -u "${RPC_USER}:${RPC_PASS}" \
    --max-time 10 \
    -H "X-Transmission-Session-Id: ${session_id}" \
    -d "${payload}" \
    "${RPC_URL}" 2>/dev/null
}

# Pause all torrents via RPC
# Note: This pauses ALL torrents, including user-intentionally-paused ones.
# On resume, ALL torrents restart. This is a deliberate simplicity trade-off:
# tracking individual torrent states would require JSON parsing (jq dependency)
# or fragile grep-based parsing. Since VPN drops are rare events, the minor
# inconvenience of manually re-pausing a few torrents is acceptable.
pause_all_torrents() {
  log "Pausing all torrents..."
  if rpc_call "torrent-stop" '{}' >/dev/null; then
    TORRENTS_PAUSED_BY_US=true
    log "All torrents paused"
  else
    log "ERROR: Failed to pause torrents via RPC"
  fi
}

# Resume all torrents (only if we paused them)
resume_all_torrents() {
  if [[ "${TORRENTS_PAUSED_BY_US}" == "true" ]]; then
    log "Resuming all torrents..."
    if rpc_call "torrent-start" '{}' >/dev/null; then
      TORRENTS_PAUSED_BY_US=false
      log "All torrents resumed"
    else
      log "ERROR: Failed to resume torrents via RPC"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Bind-Address Management
# ---------------------------------------------------------------------------

# Update Transmission's bind-address via defaults write, then restart the app.
# This is the only reliable way to change bind-address for Transmission.app (GUI).
update_bind_address() {
  local new_ip="$1"
  log "Updating bind-address to ${new_ip}..."

  # Write the preference
  defaults write org.m0k.transmission BindAddressIPv4 -string "${new_ip}"

  # Restart Transmission.app to pick up the new bind-address
  # Only quit if Transmission is currently running
  if pgrep -x "Transmission" >/dev/null 2>&1; then
    osascript -e 'quit app "Transmission"' 2>/dev/null || true
    # Wait for graceful exit (up to 60s — large resume data can take time)
    local wait_count=0
    while pgrep -x "Transmission" >/dev/null 2>&1 && [[ ${wait_count} -lt 60 ]]; do
      sleep 1
      ((wait_count += 1))
    done
    # Force-kill if graceful quit failed — bind-address MUST be applied
    if pgrep -x "Transmission" >/dev/null 2>&1; then
      log "WARNING: Transmission did not quit gracefully after 60s, force-killing"
      killall -9 Transmission 2>/dev/null || true
      sleep 2
    fi
  fi

  open -a Transmission
  sleep 3 # Allow time for Transmission to start and bind

  # Verify Transmission actually restarted
  if ! pgrep -x "Transmission" >/dev/null 2>&1; then
    log "WARNING: Transmission did not restart — retrying"
    open -a Transmission
    sleep 3
  fi

  log "Transmission restarted with bind-address ${new_ip}"
}

# ---------------------------------------------------------------------------
# VPN State Handlers
# ---------------------------------------------------------------------------

# Handle VPN going down — called on first detection of missing VPN
handle_vpn_down() {
  if [[ "${VPN_IS_DOWN}" == "false" ]]; then
    VPN_IS_DOWN=true
    log "VPN DOWN detected!"
    notify "VPN Monitor" "VPN connection lost - pausing torrents"

    # Pause torrents FIRST (while Transmission is still running and RPC is available)
    # This prevents the race where restarting Transmission auto-resumes torrents
    pause_all_torrents

    # Then set bind-address to loopback and restart to enforce the new binding
    update_bind_address "127.0.0.1"
  fi
}

# Handle VPN being up — called when VPN IP is detected
handle_vpn_up() {
  local vpn_ip="$1"

  if [[ "${VPN_IS_DOWN}" == "true" ]]; then
    # VPN restored after being down
    VPN_IS_DOWN=false
    log "VPN RESTORED with IP ${vpn_ip}"
    notify "VPN Monitor" "VPN restored (${vpn_ip}) - resuming torrents"

    update_bind_address "${vpn_ip}"
    resume_all_torrents
  elif [[ "${vpn_ip}" != "${LAST_VPN_IP}" ]] && [[ -n "${LAST_VPN_IP}" ]]; then
    # VPN IP changed without going down (server switch)
    log "VPN IP changed: ${LAST_VPN_IP} -> ${vpn_ip}"
    notify "VPN Monitor" "VPN IP changed to ${vpn_ip}"

    update_bind_address "${vpn_ip}"
  fi

  LAST_VPN_IP="${vpn_ip}"
}

# ---------------------------------------------------------------------------
# Main Loop
# ---------------------------------------------------------------------------

main() {
  log "=========================================="
  log "VPN monitor starting"
  log "=========================================="
  log "Server: ${SERVER_NAME}"
  log "Transmission RPC: ${RPC_URL}"
  log "Poll interval: ${POLL_INTERVAL}s"

  # Initial state check
  local initial_ip
  if initial_ip=$(get_vpn_ip); then
    LAST_VPN_IP="${initial_ip}"
    log "Initial VPN IP: ${initial_ip}"
    # Ensure Transmission is using the VPN IP from the start
    update_bind_address "${initial_ip}"
  else
    log "WARNING: No VPN connection detected at startup"
    handle_vpn_down
  fi

  # Main polling loop
  local loop_count=0
  while true; do
    sleep "${POLL_INTERVAL}"

    # Rotate log periodically (~every hour at 5s intervals)
    ((loop_count += 1))
    if [[ $((loop_count % 720)) -eq 0 ]]; then
      rotate_log
    fi

    # Check VPN state
    local current_ip
    if current_ip=$(get_vpn_ip); then
      handle_vpn_up "${current_ip}"
    else
      handle_vpn_down
    fi
  done
}

# Signal handling for graceful shutdown
trap 'log "VPN monitor stopping (signal received)"; exit 0' INT TERM

# Entry point
main "$@"
