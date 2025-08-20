#!/usr/bin/env bash
#
# operator-first-login.sh - One-time operator account setup
#
# This script runs automatically when the operator first logs in via LaunchAgent.
# It performs initial operator account customizations and can be re-run safely.
#
# Usage: ./operator-first-login.sh
#
# Author: Claude
# Version: 1.0
# Created: 2025-08-20

# Exit on any error
set -euo pipefail

# Configuration - config.conf is copied here by first-boot.sh
CONFIG_FILE="${HOME}/.config/operator/config.conf"

# Set defaults
SERVER_NAME="MACMINI"
OPERATOR_USERNAME="operator"
NAS_SHARE_NAME="Media"

# Override with config file if available
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "WARNING: Configuration file not found: ${CONFIG_FILE}"
  echo "Using default values"
fi

# Derived variables
CURRENT_USER=$(whoami)
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-operator-login.log"

# Ensure log directory exists
mkdir -p "$(dirname "${LOG_FILE}")"

# Logging function
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

# Wait for network mount
wait_for_network_mount() {
  local mount_path="${HOME}/.local/mnt/${NAS_SHARE_NAME}"
  local timeout=30
  local elapsed=0

  log "Waiting for network mount at ${mount_path}..."

  while [[ ${elapsed} -lt ${timeout} ]]; do
    if [[ -d "${mount_path}" ]] && [[ $(find "${mount_path}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true) -gt 0 ]]; then
      log "Network mount ready"
      return 0
    fi
    sleep 1
    ((elapsed++))
  done

  log "Warning: Network mount not available after ${timeout} seconds"
  return 1
}

# Task: Dock cleanup
setup_dock() {
  log "Setting up dock for operator account..."

  local dockutil_path="/opt/homebrew/bin/dockutil"
  if [[ ! -x "${dockutil_path}" ]]; then
    log "ERROR: dockutil not found at ${dockutil_path}"
    return 1
  fi

  # Restart Dock for clean state
  killall Dock 2>/dev/null || true
  until pgrep Dock >/dev/null 2>&1; do
    sleep 1
  done

  # Wait for network mount
  wait_for_network_mount

  # Remove unwanted apps - repeat until Terminal is gone
  log "Removing unwanted applications from dock..."
  while "${dockutil_path}" --find "/System/Applications/Utilities/Terminal.app" >/dev/null 2>&1; do
    "${dockutil_path}" \
      --remove "Messages" \
      --remove "Mail" \
      --remove "Maps" \
      --remove "Photos" \
      --remove "FaceTime" \
      --remove "Calendar" \
      --remove "Contacts" \
      --remove "Reminders" \
      --remove "Freeform" \
      --remove "TV" \
      --remove "Music" \
      --remove "News" \
      --remove "iPhone Mirroring" \
      --remove "/System/Applications/Utilities/Terminal.app" \
      2>/dev/null || true
    sleep 1
  done

  # Add desired items - repeat until Passwords is present
  log "Adding desired applications to dock..."
  while ! "${dockutil_path}" --find "/System/Applications/Passwords.app" >/dev/null 2>&1; do
    local media_path="${HOME}/.local/mnt/${NAS_SHARE_NAME}/Media"

    local add_cmd=("${dockutil_path}")
    if [[ -d "${media_path}" ]]; then
      add_cmd+=(--add "${media_path}")
    fi
    add_cmd+=(
      --add "/Applications/iTerm.app"
      --add "/Applications/Plex Media Server.app"
      --add "/System/Applications/Passwords.app"
    )

    "${add_cmd[@]}" 2>/dev/null || true
    sleep 1
  done

  log "Dock setup completed"
}

# Main execution
main() {
  log "=== Operator First-Login Setup Started ==="
  log "User: ${CURRENT_USER}"
  log "Server: ${SERVER_NAME}"

  # Validate we're running as operator
  if [[ "${CURRENT_USER}" != "${OPERATOR_USERNAME}" ]]; then
    log "ERROR: This script should run as '${OPERATOR_USERNAME}'"
    exit 1
  fi

  # Run setup tasks
  setup_dock

  log "=== Operator First-Login Setup Completed ==="
}

main "$@"
