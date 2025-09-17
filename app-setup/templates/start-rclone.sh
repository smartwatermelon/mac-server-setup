#!/usr/bin/env bash
#
# start-rclone.sh - Dropbox synchronization startup script template
#
# This script is deployed to the operator's ~/.local/bin/ directory and handles
# periodic synchronization of a Dropbox folder to the local filesystem using rclone.
#
# Template placeholders (replaced during deployment):
# - __SERVER_NAME__: Server hostname for logging
# - __DROPBOX_SYNC_FOLDER__: Dropbox folder path to sync
# - __DROPBOX_LOCAL_PATH__: Local directory where content is synced
# - __RCLONE_REMOTE_NAME__: rclone remote name for Dropbox
# - __DROPBOX_SYNC_INTERVAL__: Sync interval in minutes
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2025-08-22

# Exit on error
set -euo pipefail

# Configuration (replaced during deployment)
SERVER_NAME="__SERVER_NAME__"
DROPBOX_SYNC_FOLDER="__DROPBOX_SYNC_FOLDER__"
DROPBOX_LOCAL_PATH="__DROPBOX_LOCAL_PATH__"
RCLONE_REMOTE_NAME="__RCLONE_REMOTE_NAME__"
DROPBOX_SYNC_INTERVAL="__DROPBOX_SYNC_INTERVAL__"

# Ensure local path uses current user's HOME (not the admin's HOME from setup time)
if [[ "${DROPBOX_LOCAL_PATH}" == "/Users/"*"/.local/sync/dropbox" ]]; then
  DROPBOX_LOCAL_PATH="${HOME}/.local/sync/dropbox"
fi

# Derived configuration
SERVER_NAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${SERVER_NAME_LOWER}-rclone.log"
SYNC_INTERVAL_SECONDS=$((DROPBOX_SYNC_INTERVAL * 60))

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Logging function
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

# Wait for network connectivity
wait_for_network() {
  local max_attempts=30
  local attempt=1

  log "Waiting for network connectivity..."

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if ping -c 1 -W 1000 dropbox.com >/dev/null 2>&1; then
      log "✅ Network connectivity confirmed"
      return 0
    fi

    log "Network attempt ${attempt}/${max_attempts} - waiting 10s..."
    sleep 10
    ((attempt += 1))
  done

  log "❌ Network connectivity timeout after ${max_attempts} attempts"
  return 1
}

# Perform Dropbox synchronization
sync_dropbox() {
  local remote_path="${RCLONE_REMOTE_NAME}:${DROPBOX_SYNC_FOLDER}"

  log "Starting Dropbox synchronization..."
  log "Remote: ${remote_path}"
  log "Local: ${DROPBOX_LOCAL_PATH}"

  # Create local directory if it doesn't exist
  if [[ ! -d "${DROPBOX_LOCAL_PATH}" ]]; then
    log "Creating local sync directory: ${DROPBOX_LOCAL_PATH}"
    mkdir -p "${DROPBOX_LOCAL_PATH}"
  fi

  # Perform sync with progress and error handling
  if /opt/homebrew/bin/rclone sync "${remote_path}" "${DROPBOX_LOCAL_PATH}" \
    --progress \
    --transfers 4 \
    --checkers 8 \
    --retries 3 \
    --timeout 10m \
    --log-level INFO \
    --stats 30s; then

    log "✅ Dropbox synchronization completed successfully"

    # Log sync statistics
    local file_count
    file_count=$(find "${DROPBOX_LOCAL_PATH}" -type f | wc -l)
    local dir_size
    dir_size=$(du -sh "${DROPBOX_LOCAL_PATH}" 2>/dev/null | cut -f1)

    log "Sync statistics:"
    log "  Files: ${file_count// /}"
    log "  Size: ${dir_size}"

    return 0
  else
    log "❌ Dropbox synchronization failed"
    return 1
  fi
}

# Main execution
main() {
  log "=================================================================================="
  log "Dropbox Sync Service Starting"
  log "=================================================================================="
  log "Server: ${SERVER_NAME}"
  log "Remote folder: ${DROPBOX_SYNC_FOLDER}"
  log "Local path: ${DROPBOX_LOCAL_PATH}"
  log "rclone remote: ${RCLONE_REMOTE_NAME}"
  log "Sync interval: ${DROPBOX_SYNC_INTERVAL} minutes (${SYNC_INTERVAL_SECONDS} seconds)"

  # Wait for network
  if ! wait_for_network; then
    log "❌ Cannot proceed without network connectivity"
    exit 1
  fi

  # Test rclone configuration
  log "Testing rclone configuration..."
  log "Remote name: ${RCLONE_REMOTE_NAME}"
  log "Config file: ~/.config/rclone/rclone.conf"

  # Test with verbose output for debugging
  local test_output
  test_output=$(/opt/homebrew/bin/rclone lsd "${RCLONE_REMOTE_NAME}:" --max-depth 1 2>&1)
  local test_result=$?

  if [[ ${test_result} -eq 0 ]]; then
    log "✅ rclone configuration test successful"
  else
    log "❌ rclone configuration test failed (exit code: ${test_result})"
    log "rclone error output:"
    echo "${test_output}" | while IFS= read -r line; do
      log "  ${line}"
    done
    log "Config file status:"
    if [[ -f "${HOME}/.config/rclone/rclone.conf" ]]; then
      log "  Config file exists: ${HOME}/.config/rclone/rclone.conf"
      local config_file_perms
      config_file_perms="$(ls -l "${HOME}/.config/rclone/rclone.conf")"
      log "  Config file permissions: ${config_file_perms}"
    else
      log "  ❌ Config file missing: ${HOME}/.config/rclone/rclone.conf"
    fi
    exit 1
  fi

  # Perform initial sync
  sync_dropbox

  # Start periodic sync loop
  log "Starting periodic sync (every ${DROPBOX_SYNC_INTERVAL} minutes)..."
  while true; do
    log "Sleeping for ${DROPBOX_SYNC_INTERVAL} minutes..."
    sleep "${SYNC_INTERVAL_SECONDS}"

    log "Starting scheduled sync..."
    sync_dropbox
  done
}

# Handle signals gracefully
trap 'log "Received termination signal, shutting down..."; exit 0' SIGTERM SIGINT

# Run main function
main "$@"
