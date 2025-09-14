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
PROGRESS_LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-operator-login-progress.log"
PROGRESS_INDICATOR_PID=""

# Ensure log directories exist
mkdir -p "$(dirname "${LOG_FILE}")"
mkdir -p "$(dirname "${PROGRESS_LOG_FILE}")"

# Logging function
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

# Check ProgressIndicator availability
if command -v ProgressIndicator >/dev/null 2>&1; then
  log "ProgressIndicator available - GUI progress will be shown"
else
  log "ProgressIndicator not available - using log-only progress tracking"
fi

# Start ProgressIndicator if available and not already running
start_progress() {
  if command -v ProgressIndicator >/dev/null 2>&1; then
    if [[ -z "${PROGRESS_INDICATOR_PID}" ]] || ! kill -0 "${PROGRESS_INDICATOR_PID}" 2>/dev/null; then
      ProgressIndicator --watchfile="${PROGRESS_LOG_FILE}" &
      PROGRESS_INDICATOR_PID=$!
      if kill -0 "${PROGRESS_INDICATOR_PID}" 2>/dev/null; then
        log "Started ProgressIndicator (PID: ${PROGRESS_INDICATOR_PID})"
      else
        log "Warning: Failed to start ProgressIndicator GUI"
        PROGRESS_INDICATOR_PID=""
      fi
    fi
  fi
}

# Progress Indicator function
# wraps log()
progress() {
  start_progress
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${PROGRESS_LOG_FILE}"
  log "$*"
}

stop_progress() {
  if [[ -n "${PROGRESS_INDICATOR_PID}" ]] && kill -0 "${PROGRESS_INDICATOR_PID}" 2>/dev/null; then
    kill "${PROGRESS_INDICATOR_PID}" 2>/dev/null || true
    wait "${PROGRESS_INDICATOR_PID}" 2>/dev/null || true
    PROGRESS_INDICATOR_PID=""
    log "Stopped ProgressIndicator"
  fi
  # Fallback cleanup
  pkill -f "ProgressIndicator.*${PROGRESS_LOG_FILE}" 2>/dev/null || true
}

# Wait for network mount
wait_for_network_mount() {

  local mount_path="${HOME}/.local/mnt/${NAS_SHARE_NAME}"
  local timeout=120
  local elapsed=0

  progress "Waiting for network mount at ${mount_path}..."

  while [[ ${elapsed} -lt ${timeout} ]]; do
    # Check if there's an active SMB mount owned by current user
    if mount | grep "${CURRENT_USER}" | grep -q "${mount_path}"; then
      progress "Network mount ready (active mount found for ${CURRENT_USER})"
      return 0
    else
      progress "No active mount found for ${CURRENT_USER}, waiting... (${elapsed}s/${timeout}s)"
    fi

    sleep 1
    ((elapsed += 1))
  done

  progress "Warning: Network mount not available after ${timeout} seconds"
  return 1
}

# Task: Dock cleanup
setup_dock() {
  progress "Setting up dock for operator account..."

  if ! command -v dockutil; then
    progress "Warning: dockutil not found. Install: brew install dockutil"
    return 0
  fi

  # Restart Dock for clean state
  killall Dock 2>/dev/null || true
  sleep 1
  until pgrep Dock >/dev/null 2>&1; do
    sleep 1
  done

  # Remove unwanted apps
  progress "Removing unwanted applications from dock..."
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
      progress "Removing ${app} from dock..."
      dockutil --remove "${app}" --no-restart 2>/dev/null || true
      sleep 1
      ((elapsed += 1))
    done

    if [[ ${elapsed} -ge ${timeout} ]]; then
      progress "Warning: Timeout removing ${app} from dock"
    fi
  done

  # Add desired items
  progress "Adding desired applications to dock..."
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
      progress "Adding ${app} to dock..."
      dockutil --add "${app}" --no-restart 2>/dev/null || true
      sleep 1
      ((elapsed += 1))
    done

    if [[ ${elapsed} -ge ${timeout} ]]; then
      progress "Warning: Timeout adding ${app} to dock"
    fi
  done

  # Restart Dock to apply changes
  killall Dock 2>/dev/null || true
  sleep 1

  progress "Dock setup completed"
}

# Task: Configure Terminal profile
setup_terminal_profile() {
  progress "Setting up Terminal profile..."

  local terminal_config_dir="${HOME}/.config/terminal"
  local profile_file="${terminal_config_dir}/Orangebrew.terminal"

  # Check if profile file exists
  if [[ ! -f "${profile_file}" ]]; then
    progress "No Terminal profile found at ${profile_file} - skipping terminal setup"
    return 0
  fi

  # Extract profile name
  local profile_name
  if ! profile_name=$(plutil -extract name raw "${profile_file}" 2>/dev/null); then
    progress "Warning: Could not extract profile name from ${profile_file}"
    return 0
  fi

  progress "Registering Terminal profile '${profile_name}'..."

  # Step 1: Open the profile file to register it with Terminal.app
  if open "${profile_file}"; then
    progress "Successfully opened Terminal profile file"

    # Step 2: Set as default window settings
    defaults write com.apple.Terminal "Default Window Settings" -string "${profile_name}"

    # Step 3: Set as startup window settings
    defaults write com.apple.Terminal "Startup Window Settings" -string "${profile_name}"

    # Step 4: Close the Terminal window that was opened
    sleep 2 # Brief pause to let Terminal register the profile
    killall Terminal 2>/dev/null || true

    progress "Terminal profile '${profile_name}' configured successfully"
  else
    progress "Warning: Failed to open Terminal profile file"
  fi
}

# Task: Configure iTerm2 preferences
setup_iterm2_preferences() {
  progress "Setting up iTerm2 preferences..."

  local iterm2_config_dir="${HOME}/.config/iterm2"
  local preferences_file="${iterm2_config_dir}/iterm2.plist"

  # Check if preferences file exists
  if [[ ! -f "${preferences_file}" ]]; then
    progress "No iTerm2 preferences found at ${preferences_file} - skipping iTerm2 setup"
    return 0
  fi

  # Check if iTerm2 is installed (more reliable detection method)
  if [[ ! -d /Applications/iTerm.app ]]; then
    progress "iTerm2 not installed - skipping preferences import"
    return 0
  fi

  progress "Importing iTerm2 preferences..."

  # Ensure iTerm2 is not running during import for better reliability
  if pgrep -f "iTerm.app" >/dev/null 2>&1; then
    progress "iTerm2 is currently running - preferences import may not take effect until restart"
  fi

  # Import preferences using defaults import
  if defaults import com.googlecode.iterm2 "${preferences_file}"; then
    progress "iTerm2 preferences import command succeeded"

    # Verify that import actually worked by checking for a key preference
    if defaults read com.googlecode.iterm2 "Default Bookmark Guid" >/dev/null 2>&1; then
      progress "✅ Successfully imported and verified iTerm2 preferences"
      progress "Preferences will be active when iTerm2 is next launched"
    else
      progress "⚠️ Import command succeeded but preferences verification failed"
      progress "iTerm2 preferences may not have been properly imported"
    fi
  else
    progress "❌ Failed to import iTerm2 preferences"
    progress "Check that preferences file is valid: ${preferences_file}"
    progress "You can manually import by opening iTerm2 > Preferences > Profiles > Other Actions > Import JSON Profiles"
  fi
}

# Task: Start logrotate service
setup_logrotate() {
  progress "Starting logrotate service for operator user..."
  brew services stop logrotate &>/dev/null || true
  if brew services start logrotate; then
    progress "Logrotate service started successfully"
  else
    progress "Warning: Failed to start logrotate service - logs will not be rotated"
  fi
}

# Task: unload LaunchAgent
unload_launchagent() {
  progress "Unloading LaunchAgent..."
  local launch_agents_dir="${HOME}/Library/LaunchAgents"
  local launch_agent="com.${HOSTNAME_LOWER}.operator-first-login.plist"
  local operator_config_dir
  operator_config_dir="$(dirname "${CONFIG_FILE}")"
  if mv "${launch_agents_dir}/${launch_agent}" "${operator_config_dir}"; then
    progress "Moved LaunchAgent to ${operator_config_dir}"
    progress "(Move back to ${launch_agents_dir} to re-run on next login)"
  else
    progress "Warning: Failed to rename LaunchAgent; it will probably reload on next login"
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
  progress "=== Operator First-Login Setup Started ==="
  log "User: ${CURRENT_USER}"
  log "Server: ${SERVER_NAME}"

  # Validate we're running as operator
  if [[ "${CURRENT_USER}" != "${OPERATOR_USERNAME}" ]]; then
    log "ERROR: This script should run as '${OPERATOR_USERNAME}'"
    exit 1
  fi

  # Run setup tasks
  setup_dock
  setup_terminal_profile
  setup_iterm2_preferences
  setup_logrotate
  unload_launchagent

  progress "=== Operator First-Login Setup Completed ==="
  sleep 2
  stop_progress
}

main "$@"
