#!/usr/bin/env bash
#
# plex-vpn-bypass.sh - PF-based Plex VPN Bypass and Public IP Monitor
#
# Maintains PF (Packet Filter) rules that allow Plex Media Server to accept
# incoming connections and route outbound traffic directly via the physical
# network interface, bypassing the VPN tunnel. Also monitors the public IP
# and updates Plex's customConnections setting when it changes.
#
# WHY THIS EXISTS:
# PIA's macOS split tunnel transparent proxy is fundamentally broken — it
# intercepts bypass-app traffic and binds to the physical IP, but flow
# forwarding fails with "Empty buffer" and "ioOnClosedChannel" for ALL
# bypass apps. This script works around the bug at the kernel level using
# PF route-to rules, which operate below PIA's userspace proxy.
#
# See docs/pia-split-tunnel-bug.md for full bug documentation.
#
# WHAT IT DOES (every 60 seconds):
#   1. ENSURE PF RULES — check anchor, reload if missing or network changed
#      - pass in: allow inbound TCP to port 32400 on physical interface
#      - pass out: route-to physical gateway for outbound non-RFC1918 traffic
#   2. CHECK PUBLIC IP — curl via physical interface
#      - If changed: update Plex customConnections, log, notify
#   3. LOG ROTATION — same 5MB pattern as other monitors
#
# RUNS AS: root (via LaunchDaemon — required for pfctl operations)
#
# Template placeholders (replaced during deployment):
#   - __SERVER_NAME__: Server hostname for logging and notifications
#   - __OPERATOR_USERNAME__: Operator account username for token lookup and notifications
#
# Usage: Launched automatically by LaunchDaemon
#   Not intended for manual execution.
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-16

set -euo pipefail

# Configuration (replaced during deployment)
SERVER_NAME="__SERVER_NAME__"
OPERATOR_USERNAME="__OPERATOR_USERNAME__"

# Derived configuration
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
POLL_INTERVAL=60
PF_ANCHOR="com.apple/100.${HOSTNAME_LOWER}.vpn-bypass"

# Logging configuration
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-plex-vpn-bypass.log"
MAX_LOG_SIZE=5242880 # 5MB

# State tracking
LAST_PUBLIC_IP=""
LAST_NETWORK_CONFIG=""

# Network detection globals (set by detect_physical_network)
PHYS_IFACE=""
PHYS_IP=""
PHYS_GATEWAY=""

# ---------------------------------------------------------------------------
# Logging & Notification
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [plex-vpn-bypass] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

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

notify() {
  local title="$1"
  local message="$2"
  # Deliver notification as the operator user (needs their Homebrew PATH)
  if sudo -iu "${OPERATOR_USERNAME}" command -v terminal-notifier >/dev/null 2>&1; then
    sudo -iu "${OPERATOR_USERNAME}" terminal-notifier \
      -title "${title}" \
      -message "${message}" \
      -group "plex-vpn-bypass" \
      -sender "com.plexapp.plexmediaserver" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Network Detection
# ---------------------------------------------------------------------------

# Detect the primary physical (non-VPN) network interface, its IP, and gateway.
# Sets globals: PHYS_IFACE, PHYS_IP, PHYS_GATEWAY
detect_physical_network() {
  PHYS_IFACE=""
  PHYS_IP=""
  PHYS_GATEWAY=""

  # Try common physical interfaces (en0 is primary on Mac)
  local iface_candidate candidate_ip candidate_gw
  for iface_candidate in en0 en1 en2; do
    candidate_ip=$(ifconfig "${iface_candidate}" 2>/dev/null \
      | awk '/inet / && !/127\./ {print $2}' | head -1)
    if [[ -z "${candidate_ip}" ]]; then
      continue
    fi

    candidate_gw=$(route -n get -ifscope "${iface_candidate}" default 2>/dev/null \
      | awk '/gateway:/ {print $2}')

    if [[ -n "${candidate_gw}" ]]; then
      PHYS_IFACE="${iface_candidate}"
      PHYS_IP="${candidate_ip}"
      PHYS_GATEWAY="${candidate_gw}"
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# PF Rule Management
# ---------------------------------------------------------------------------

# Generate PF rules for the current network state
generate_pf_rules() {
  cat <<EOF
table <rfc1918> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 }
pass in quick on ${PHYS_IFACE} proto tcp to port 32400
pass out quick route-to (${PHYS_IFACE} ${PHYS_GATEWAY}) from ${PHYS_IP} to ! <rfc1918>
EOF
}

# Load PF rules into the anchor
load_pf_rules() {
  local rules
  rules=$(generate_pf_rules)

  log "Loading PF rules into anchor ${PF_ANCHOR}:"
  while IFS= read -r line; do
    log "  ${line}"
  done <<<"${rules}"

  local pfctl_output
  if pfctl_output=$(echo "${rules}" | pfctl -a "${PF_ANCHOR}" -f - 2>&1); then
    log "PF rules loaded successfully"
  else
    log "ERROR: Failed to load PF rules: ${pfctl_output}"
    return 1
  fi

  # Ensure PF is enabled (no-op if already enabled)
  pfctl -e 2>/dev/null || true

  LAST_NETWORK_CONFIG="${PHYS_IFACE}:${PHYS_IP}:${PHYS_GATEWAY}"
  return 0
}

# Ensure PF rules are loaded and match the current network config
ensure_pf_rules() {
  local needs_reload=false

  # Check if anchor is empty
  local current_rules
  current_rules=$(pfctl -a "${PF_ANCHOR}" -sr 2>/dev/null || true)
  if [[ -z "${current_rules}" ]]; then
    log "PF anchor is empty — rules need loading"
    needs_reload=true
  fi

  # Check if network config changed since last load
  local current_config="${PHYS_IFACE}:${PHYS_IP}:${PHYS_GATEWAY}"
  if [[ "${current_config}" != "${LAST_NETWORK_CONFIG}" ]]; then
    log "Network config changed (${LAST_NETWORK_CONFIG:-<none>} -> ${current_config})"
    needs_reload=true
  fi

  if [[ "${needs_reload}" == "true" ]]; then
    load_pf_rules || log "ERROR: PF rule reload failed"
  fi
}

# ---------------------------------------------------------------------------
# Plex Integration
# ---------------------------------------------------------------------------

# Get Plex authentication token from the operator user's config files.
# Checks transmission-done config first (explicit token), then falls back
# to Plex's own Preferences.xml.
get_plex_token() {
  local token=""
  local user_home="/Users/${OPERATOR_USERNAME}"

  # Source 1: transmission-done config (media pipeline setup stores token here)
  local td_config="${user_home}/.config/transmission-done/config.yml"
  if [[ -f "${td_config}" ]]; then
    token=$(grep -A5 '^plex:' "${td_config}" | awk '/token:/ {print $2; exit}')
  fi

  # Source 2: Plex Preferences.xml (standard Plex location)
  if [[ -z "${token}" ]]; then
    local plex_prefs="${user_home}/Library/Application Support/Plex Media Server/Preferences.xml"
    if [[ -f "${plex_prefs}" ]]; then
      token=$(sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "${plex_prefs}")
    fi
  fi

  if [[ -z "${token}" ]]; then
    log "WARNING: Plex token not found in ${td_config} or Preferences.xml"
    return 1
  fi

  echo "${token}"
}

# Update Plex customConnections setting via the local API
update_plex_custom_connections() {
  local public_ip="$1"
  local custom_url="https://${public_ip}:32400"

  local token
  if ! token=$(get_plex_token); then
    log "ERROR: Cannot update Plex — no token available"
    return 1
  fi

  # URL-encode the custom connections value (safe against special chars)
  local encoded_url
  encoded_url=$(python3 -c \
    "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" \
    "${custom_url}")

  log "Updating Plex customConnections to ${custom_url}"

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    "http://localhost:32400/:/prefs?customConnections=${encoded_url}&X-Plex-Token=${token}" \
    --max-time 10)

  if [[ "${http_code}" == "200" ]]; then
    log "Plex customConnections updated successfully"
    return 0
  else
    log "ERROR: Plex API returned HTTP ${http_code}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Public IP Monitoring
# ---------------------------------------------------------------------------

# Check the current public IP via the physical interface
check_public_ip() {
  if [[ -z "${PHYS_IP}" ]]; then
    return 1
  fi

  local ip
  ip=$(curl -s --interface "${PHYS_IP}" --max-time 10 \
    "http://checkip.amazonaws.com" 2>/dev/null | tr -d '[:space:]')

  if [[ -z "${ip}" ]]; then
    return 1
  fi

  echo "${ip}"
}

# ---------------------------------------------------------------------------
# Main Loop
# ---------------------------------------------------------------------------

main() {
  log "=========================================="
  log "Plex VPN Bypass monitor starting"
  log "=========================================="
  log "Server: ${SERVER_NAME}"
  log "Poll interval: ${POLL_INTERVAL}s"
  log "PF anchor: ${PF_ANCHOR}"

  # Initial network detection
  if detect_physical_network; then
    log "Physical interface: ${PHYS_IFACE}"
    log "Physical IP: ${PHYS_IP}"
    log "Gateway: ${PHYS_GATEWAY}"
  else
    log "WARNING: Could not detect physical network at startup — will retry"
  fi

  # Initial PF rule load
  if [[ -n "${PHYS_IFACE}" ]]; then
    load_pf_rules || log "WARNING: Initial PF rule load failed — will retry"
  fi

  # Initial public IP check
  local initial_ip
  if initial_ip=$(check_public_ip); then
    LAST_PUBLIC_IP="${initial_ip}"
    log "Initial public IP: ${initial_ip}"
    # Update Plex on startup to ensure customConnections is current
    update_plex_custom_connections "${initial_ip}" \
      || log "WARNING: Initial Plex update failed — will retry on next change"
  else
    log "WARNING: Could not determine public IP at startup — will retry"
  fi

  # Main polling loop
  local loop_count=0
  while true; do
    sleep "${POLL_INTERVAL}"

    # Rotate log periodically (~every hour at 60s intervals)
    ((loop_count += 1))
    if [[ $((loop_count % 60)) -eq 0 ]]; then
      rotate_log
    fi

    # 1. Re-detect network (interface/IP/gateway may change)
    if ! detect_physical_network; then
      log "WARNING: Physical network not detected — skipping this cycle"
      continue
    fi

    # 2. Ensure PF rules are loaded and current
    ensure_pf_rules

    # 3. Check public IP for changes
    local current_ip
    if current_ip=$(check_public_ip); then
      if [[ "${current_ip}" != "${LAST_PUBLIC_IP}" ]]; then
        log "Public IP changed: ${LAST_PUBLIC_IP:-<unknown>} -> ${current_ip}"
        notify "Plex VPN Bypass" "Public IP changed to ${current_ip}"
        if update_plex_custom_connections "${current_ip}"; then
          LAST_PUBLIC_IP="${current_ip}"
        else
          log "WARNING: Plex update failed — will retry next cycle"
        fi
      fi
    else
      log "WARNING: Public IP check failed (keeping last known: ${LAST_PUBLIC_IP:-<unknown>})"
    fi
  done
}

# Signal handling for graceful shutdown
cleanup() {
  log "Plex VPN Bypass monitor stopping (signal received)"
  # PF rules persist in the anchor — intentionally not flushing them on stop
  # so Plex stays accessible even if the monitor is temporarily down
  exit 0
}
trap cleanup INT TERM

# Entry point
main "$@"
