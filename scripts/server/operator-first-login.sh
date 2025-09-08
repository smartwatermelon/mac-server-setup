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

# Load Homebrew paths from system-wide configuration (LaunchAgent doesn't inherit PATH)
if [[ -f "/etc/paths.d/homebrew" ]]; then
  HOMEBREW_PATHS=$(cat /etc/paths.d/homebrew)
  export PATH="${HOMEBREW_PATHS}:${PATH}"
fi

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
  local timeout=120
  local elapsed=0

  log "Waiting for network mount at ${mount_path}..."

  while [[ ${elapsed} -lt ${timeout} ]]; do
    # Check if there's an active SMB mount owned by current user
    if mount | grep "${CURRENT_USER}" | grep -q "${mount_path}"; then
      log "Network mount ready (active mount found for ${CURRENT_USER})"
      return 0
    else
      log "No active mount found for ${CURRENT_USER}, waiting... (${elapsed}s/${timeout}s)"
    fi

    # Show progress dialog every 10 seconds
    if [[ $((elapsed % 10)) -eq 0 && ${elapsed} -gt 0 ]]; then
      osascript -e "display dialog \"Waiting for network storage to be ready...\\n\\nElapsed: ${elapsed}s / ${timeout}s\" buttons {\"OK\"} default button \"OK\" giving up after 3 with title \"Mac Mini Setup\"" >/dev/null 2>&1 || true
    fi

    sleep 1
    ((elapsed += 1))
  done

  log "Warning: Network mount not available after ${timeout} seconds"
  return 1
}

# Task: Dock cleanup
setup_dock() {
  log "Setting up dock for operator account..."

  if ! command -v dockutil; then
    log "Warning: dockutil not found. Install: brew install dockutil"
    return 0
  fi

  # Restart Dock for clean state
  killall Dock 2>/dev/null || true
  sleep 1
  until pgrep Dock >/dev/null 2>&1; do
    sleep 1
  done

  # Remove unwanted apps
  log "Removing unwanted applications from dock..."
  local apps_to_remove=(
    "Messages"
    "Mail"
    "Maps"
    "Photos"
    "FaceTime"
    "Calendar"
    "Contacts"
    "Reminders"
    "Freeform"
    "TV"
    "Music"
    "News"
    "iPhone Mirroring"
    "/System/Applications/Utilities/Terminal.app"
  )

  for app in "${apps_to_remove[@]}"; do
    local timeout=30
    local elapsed=0

    while dockutil --find "${app}" >/dev/null 2>&1 && [[ ${elapsed} -lt ${timeout} ]]; do
      log "Removing ${app} from dock..."
      dockutil --remove "${app}" --no-restart 2>/dev/null || true
      sleep 1
      ((elapsed += 1))
    done

    if [[ ${elapsed} -ge ${timeout} ]]; then
      log "Warning: Timeout removing ${app} from dock"
    fi
  done

  # Add desired items
  log "Adding desired applications to dock..."
  local media_path="${HOME}/.local/mnt/${NAS_SHARE_NAME}/Media"
  local apps_to_add=()

  # Add media path if it exists
  if [[ -d "${media_path}" ]]; then
    apps_to_add+=("${media_path}")
  fi

  apps_to_add+=(
    "/Applications/iTerm.app"
    "/Applications/Plex Media Server.app"
    "/System/Applications/Passwords.app"
  )

  for app in "${apps_to_add[@]}"; do
    local timeout=30
    local elapsed=0

    while ! dockutil --find "${app}" >/dev/null 2>&1 && [[ ${elapsed} -lt ${timeout} ]]; do
      log "Adding ${app} to dock..."
      dockutil --add "${app}" --no-restart 2>/dev/null || true
      sleep 1
      ((elapsed += 1))
    done

    if [[ ${elapsed} -ge ${timeout} ]]; then
      log "Warning: Timeout adding ${app} to dock"
    fi
  done

  # Restart Dock to apply changes
  killall Dock 2>/dev/null || true
  sleep 1

  log "Dock setup completed"
}

# Task: Start logrotate service
setup_logrotate() {
  log "Starting logrotate service for operator user..."
  brew services stop logrotate &>/dev/null || true
  if brew services start logrotate; then
    log "Logrotate service started successfully"
  else
    log "Warning: Failed to start logrotate service - logs will not be rotated"
  fi
}

# Task: unload LaunchAgent
unload_launchagent() {
  log "Unloading LaunchAgent..."
  local LaunchAgent="com.${HOSTNAME_LOWER}.operator-first-login.plist"
  if launchctl unload "${HOME}/Library/LaunchAgents/${LaunchAgent}"; then
    log "Unloaded LaunchAgent"
  else
    log "Warning: Failed to unload LaunchAgent"
  fi
}

# Task: lock screen
lock_screen_now() {
  log "Locking screen..."
  if pmset displaysleepnow; then
    log "Screen locked successfully"
  else
    log "Unable to lock screen, u r hax0r3d"
  fi
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

  # Show setup notification to user
  osascript -e 'display dialog "🔧 Setting up operator account...\n\nCustomizing dock and applications.\nThis will complete automatically in a few moments." buttons {"OK"} default button "OK" giving up after 8 with title "Mac Mini Setup"'

  # Run setup tasks
  setup_dock
  setup_logrotate
  unload_launchagent

  # Show setup notification to user
  osascript -e 'display dialog "✅ Done setting up operator account!" buttons {"OK"} default button "OK" giving up after 8 with title "Mac Mini Setup"'

  log "=== Operator First-Login Setup Completed ==="
}

main "$@"
