#!/usr/bin/env bash
#
# vpn-monitor.sh - VPN state monitor for Transmission
#
# Monitors VPN tunnel interfaces (utun*) and manages Transmission accordingly:
# - VPN UP:       Ensures Transmission is running with VPN IP as bind-address
# - VPN IP CHANGE: Updates bind-address, restarts Transmission
# - VPN DROP:     Kills Transmission (zero network activity guaranteed)
# - VPN RESTORE:  Updates bind-address, relaunches Transmission
#
# Kill-and-restart is more reliable than RPC pause/resume:
# - A dead process has zero network activity (no DHT, PEX, tracker leaks)
# - Transmission persists torrent state — previously-active torrents resume,
#   paused ones stay paused, no external state tracking needed
# - No RPC dependency for the critical "stop all traffic" path
#
# This script runs as a LaunchAgent under the operator user, alongside
# Transmission.app (GUI).
#
# Template placeholders (replaced during deployment):
# - __SERVER_NAME__: Server hostname for logging and preferences
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
POLL_INTERVAL=5

# Logging configuration
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-vpn-monitor.log"
MAX_LOG_SIZE=5242880 # 5MB

# State tracking
LAST_VPN_IP=""
VPN_IS_DOWN=false

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
# Transmission Process Management
# ---------------------------------------------------------------------------

# Kill Transmission and verify it is dead.
# Uses graceful quit first, then force-kill as fallback.
kill_transmission() {
  if ! pgrep -x "Transmission" >/dev/null 2>&1; then
    log "Transmission is not running"
    return 0
  fi

  log "Killing Transmission..."
  osascript -e 'quit app "Transmission"' 2>/dev/null || true

  # Wait for graceful exit (up to 10s)
  local wait_count=0
  while pgrep -x "Transmission" >/dev/null 2>&1 && [[ ${wait_count} -lt 10 ]]; do
    sleep 1
    ((wait_count += 1))
  done

  # Force-kill if graceful quit failed
  if pgrep -x "Transmission" >/dev/null 2>&1; then
    log "WARNING: Graceful quit failed after 10s, force-killing"
    killall -9 Transmission 2>/dev/null || true
    sleep 2
  fi

  # Final verification
  if pgrep -x "Transmission" >/dev/null 2>&1; then
    log "ERROR: Transmission is STILL running after force-kill!"
    return 1
  fi

  log "Transmission killed"
  return 0
}

# Launch Transmission and verify it is running.
launch_transmission() {
  log "Launching Transmission..."
  open -a Transmission
  sleep 3

  if ! pgrep -x "Transmission" >/dev/null 2>&1; then
    log "WARNING: Transmission did not start — retrying"
    open -a Transmission
    sleep 3
  fi

  local pid
  pid=$(pgrep -x "Transmission" || true)
  if [[ -n "${pid}" ]]; then
    log "Transmission launched (PID ${pid})"
    return 0
  else
    log "ERROR: Transmission failed to launch"
    return 1
  fi
}

# Update Transmission's bind-address preference.
# Transmission reads this on launch — call before launch_transmission().
set_bind_address() {
  local ip="$1"
  defaults write org.m0k.transmission BindAddressIPv4 -string "${ip}"
  log "Bind-address set to ${ip}"
}

# ---------------------------------------------------------------------------
# VPN State Handlers
# ---------------------------------------------------------------------------

# Handle VPN going down — kill Transmission immediately
handle_vpn_down() {
  if [[ "${VPN_IS_DOWN}" == "false" ]]; then
    VPN_IS_DOWN=true
    log "VPN DOWN detected!"
    notify "VPN Monitor" "VPN connection lost — killing Transmission"
    kill_transmission
    set_bind_address "127.0.0.1"
  fi
}

# Handle VPN being up — set bind-address and launch if needed
handle_vpn_up() {
  local vpn_ip="$1"

  if [[ "${VPN_IS_DOWN}" == "true" ]]; then
    # VPN restored after being down
    VPN_IS_DOWN=false
    log "VPN RESTORED with IP ${vpn_ip}"
    notify "VPN Monitor" "VPN restored (${vpn_ip}) — launching Transmission"
    set_bind_address "${vpn_ip}"
    launch_transmission
  elif [[ "${vpn_ip}" != "${LAST_VPN_IP}" ]] && [[ -n "${LAST_VPN_IP}" ]]; then
    # VPN IP changed without going down (server switch)
    log "VPN IP changed: ${LAST_VPN_IP} -> ${vpn_ip}"
    notify "VPN Monitor" "VPN IP changed to ${vpn_ip}"
    set_bind_address "${vpn_ip}"
    kill_transmission
    launch_transmission
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
  log "Poll interval: ${POLL_INTERVAL}s"

  # Initial state check
  local initial_ip
  if initial_ip=$(get_vpn_ip); then
    LAST_VPN_IP="${initial_ip}"
    log "Initial VPN IP: ${initial_ip}"
    # Ensure Transmission is using the VPN IP from the start
    set_bind_address "${initial_ip}"
    local pid
    pid=$(pgrep -x "Transmission" || true)
    if [[ -z "${pid}" ]]; then
      launch_transmission
    else
      log "Transmission already running (PID ${pid})"
    fi
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
