#!/usr/bin/env bash
#
# start-plex-with-mount.sh - Wait for SMB mount then start Plex Media Server
#
# This script waits for the SMB media mount to be available before
# starting Plex Media Server to ensure media is accessible.
#
# Template placeholders (replaced by plex-setup.sh):
#   __SERVER_NAME__ - Server name for logging
#   __NAS_SHARE_NAME__ - SMB share name to wait for
#
# Author: Claude
# Version: 1.0
# Created: 2025-08-21

set -euo pipefail

# Load configuration
CONFIG_FILE="${HOME}/.config/operator/config.conf"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  # Fallback defaults (replaced by plex-setup.sh)
  SERVER_NAME="__SERVER_NAME__"
  NAS_SHARE_NAME="__NAS_SHARE_NAME__"
fi

# Derived variables
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-plex-startup.log"
MOUNT_PATH="${HOME}/.local/mnt/${NAS_SHARE_NAME}"
PLEX_APP="/Applications/Plex Media Server.app"

# Ensure log directory exists
mkdir -p "$(dirname "${LOG_FILE}")"

# Logging function
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

# Wait for network mount
wait_for_mount() {
  local timeout=120
  local elapsed=0

  log "Waiting for network mount at ${MOUNT_PATH}..."

  while [[ ${elapsed} -lt ${timeout} ]]; do
    if [[ -d "${MOUNT_PATH}" ]]; then
      # Check if we can actually read the mount directory (indicating it's a working mount)
      if ls "${MOUNT_PATH}" >/dev/null 2>&1; then
        local item_count
        item_count=$(find "${MOUNT_PATH}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        log "Network mount ready and accessible (found ${item_count} items)"
        return 0
      else
        log "Mount directory exists but not accessible, waiting... (${elapsed}s/${timeout}s)"
      fi
    else
      log "Mount directory does not exist, waiting... (${elapsed}s/${timeout}s)"
    fi

    sleep 2
    ((elapsed += 2))
  done

  log "Warning: Network mount not available after ${timeout} seconds - starting Plex anyway"
  return 1
}

# Wait for Plex to be fully ready and open web interface
open_plex_web_interface() {
  local timeout=60
  local elapsed=0

  log "Waiting for Plex web interface to be ready..."

  while [[ ${elapsed} -lt ${timeout} ]]; do
    if curl -s "http://localhost:32400/web" >/dev/null 2>&1; then
      log "Plex web interface is ready, opening browser..."
      open "http://localhost:32400/web"
      return 0
    fi
    sleep 2
    ((elapsed += 2))
  done

  log "Warning: Plex web interface not ready after ${timeout} seconds"
  return 1
}

# Main execution
log "=== Plex Startup with Mount Check ==="
wait_for_mount

log "Starting Plex Media Server..."

# Start Plex in background and get its PID
"${PLEX_APP}/Contents/MacOS/Plex Media Server" &
plex_pid=$!

# Wait a moment for Plex to initialize
sleep 5

# Open web interface once Plex is ready
open_plex_web_interface &

# Wait for the Plex process (exec replacement)
wait "${plex_pid}"
