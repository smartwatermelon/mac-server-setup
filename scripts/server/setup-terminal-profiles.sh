#!/usr/bin/env bash
#
# setup-terminal-profiles.sh - Terminal profile configuration module
#
# This script configures terminal applications with custom profiles for better
# accessibility and visibility. Imports user-specified profiles and sets them
# as defaults for both admin and operator users to ensure consistent terminal
# appearance across all sessions.
#
# Usage: ./setup-terminal-profiles.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude (modularized from terminal setup research)
# Version: 1.0
# Created: 2025-09-09

# Exit on any error
set -euo pipefail

# Parse command line arguments
FORCE=false
for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Load common configuration
SETUP_DIR="${SETUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Set derived variables
ADMIN_USERNAME=$(whoami)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
# Set fallback for OPERATOR_USERNAME if not defined in config
OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"

# Set up logging
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# log function - only writes to log file
log() {
  local timestamp no_newline=false
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  # Check for -n flag
  if [[ "$1" == "-n" ]]; then
    no_newline=true
    shift
  fi

  if [[ "${no_newline}" == true ]]; then
    echo -n "[${timestamp}] $1" >>"${LOG_FILE}"
  else
    echo "[${timestamp}] $1" >>"${LOG_FILE}"
  fi
}

# New wrapper function - shows in main window AND logs
show_log() {
  local no_newline=false

  # Check for -n flag
  if [[ "$1" == "-n" ]]; then
    no_newline=true
    echo -n "$2"
    log -n "$2"
  else
    echo "$1"
    log "$1"
  fi
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Error collection system (minimal for module)
COLLECTED_ERRORS=()
CURRENT_SCRIPT_SECTION=""

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

# Function to collect an error (with immediate display)
collect_error() {
  local message="$1"
  local line_number="${2:-}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  COLLECTED_ERRORS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to check if a command was successful
check_success() {
  if [[ $? -eq 0 ]]; then
    show_log "✅ $1"
  else
    collect_error "$1 failed"
    if [[ "${FORCE}" = false ]]; then
      read -p "Continue anyway? (y/N) " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Terminal configuration paths
# Use profiles/preferences from the deployment package config directory
if [[ -n "${TERMINAL_PROFILE_FILE:-}" ]]; then
  TERMINAL_PROFILE_PATH="${SETUP_DIR}/config/${TERMINAL_PROFILE_FILE}"
else
  TERMINAL_PROFILE_PATH=""
fi

# iTerm2 preferences path (exported plist file)
ITERM2_PREFERENCES_PATH="${SETUP_DIR}/config/iterm2.plist"

# Backup preferences for a user
backup_user_preferences() {
  local username="$1"
  local user_home="/Users/${username}"
  local backup_dir
  backup_dir="${LOG_DIR}/terminal-profiles-backup-$(date +%Y%m%d-%H%M%S)"

  mkdir -p "${backup_dir}"

  # Backup Terminal preferences
  local terminal_plist="${user_home}/Library/Preferences/com.apple.Terminal.plist"
  if [[ -f "${terminal_plist}" ]]; then
    cp "${terminal_plist}" "${backup_dir}/terminal-${username}.plist"
    log "Backed up Terminal preferences for ${username}"
  fi

  # Backup iTerm2 preferences
  local iterm2_plist="${user_home}/Library/Preferences/com.googlecode.iterm2.plist"
  if [[ -f "${iterm2_plist}" ]]; then
    cp "${iterm2_plist}" "${backup_dir}/iterm2-${username}.plist"
    log "Backed up iTerm2 preferences for ${username}"
  fi

  echo "${backup_dir}"
}

# Import Terminal profile for a user
import_terminal_profile_for_user() {
  local username="$1"
  local profile_file="$2"

  if [[ ! -f "${profile_file}" ]]; then
    log "Terminal profile file not found: ${profile_file}"
    return 1
  fi

  # Extract profile name from the plist
  local profile_name
  if ! profile_name=$(plutil -extract name raw "${profile_file}" 2>/dev/null); then
    log "Could not extract profile name from ${profile_file}"
    return 1
  fi

  log "Importing Terminal profile '${profile_name}' for user: ${username}"

  # Create temporary profile file
  local temp_profile="/tmp/terminal-profile-${username}-$$.plist"
  if ! cp "${profile_file}" "${temp_profile}"; then
    collect_error "Failed to create temporary profile file for ${username}"
    return 1
  fi

  # Import the profile using sudo if not current user
  if [[ "${username}" == "${ADMIN_USERNAME}" ]]; then
    # Import for current admin user
    if defaults import com.apple.Terminal "${temp_profile}" \
      && defaults write com.apple.Terminal "Default Window Settings" "${profile_name}"; then
      log "Successfully imported Terminal profile for ${username}"
    else
      collect_error "Failed to import Terminal profile for ${username}"
      rm -f "${temp_profile}"
      return 1
    fi
  else
    # Import for operator user using sudo
    if sudo -u "${username}" defaults import com.apple.Terminal "${temp_profile}" \
      && sudo -u "${username}" defaults write com.apple.Terminal "Default Window Settings" "${profile_name}"; then
      log "Successfully imported Terminal profile for ${username}"
    else
      collect_error "Failed to import Terminal profile for ${username}"
      rm -f "${temp_profile}"
      return 1
    fi
  fi

  # Clean up
  rm -f "${temp_profile}"
  return 0
}

# Import iTerm2 preferences for a user using defaults import
import_iterm2_preferences_for_user() {
  local username="$1"
  local preferences_file="$2"

  if [[ ! -f "${preferences_file}" ]]; then
    log "iTerm2 preferences file not found: ${preferences_file}"
    return 1
  fi

  log "Importing iTerm2 preferences for user: ${username}"

  # Check if iTerm2 is installed
  if ! command -v it2check >/dev/null 2>&1; then
    log "iTerm2 not installed - skipping preferences import"
    return 0
  fi

  # Import preferences for the specified user
  if [[ "${username}" == "${ADMIN_USERNAME}" ]]; then
    # Current user - import directly
    if defaults import com.googlecode.iterm2 "${preferences_file}"; then
      log "Successfully imported iTerm2 preferences for current user"
    else
      collect_error "Failed to import iTerm2 preferences for current user"
      return 1
    fi
  else
    # Different user - use sudo
    if sudo -u "${username}" defaults import com.googlecode.iterm2 "${preferences_file}"; then
      log "Successfully imported iTerm2 preferences for ${username}"
    else
      collect_error "Failed to import iTerm2 preferences for ${username}"
      return 1
    fi
  fi

  log "iTerm2 preferences imported - restart iTerm2 to see changes"
  return 0
}

# Check if terminal applications are running
check_running_terminal_apps() {
  local apps_running=false

  if pgrep -f "Terminal.app" >/dev/null 2>&1; then
    log "Warning: Terminal.app is currently running"
    apps_running=true
  fi

  if pgrep -f "iTerm.app" >/dev/null 2>&1; then
    log "Warning: iTerm2 is currently running"
    apps_running=true
  fi

  if [[ "${apps_running}" == "true" ]]; then
    log "Recommendation: Terminal profile changes are more reliable when apps are closed"
  fi
}

# Main terminal profile configuration function
configure_terminal_profiles() {
  set_section "Configuring Terminal Profiles"

  # Check if terminal apps are running
  check_running_terminal_apps

  # Create backups for both users
  log "Creating preference backups..."
  backup_user_preferences "${ADMIN_USERNAME}"

  if dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
    backup_user_preferences "${OPERATOR_USERNAME}"
  else
    log "Operator user not found - will configure when account is created"
  fi

  # Import Terminal profiles
  if [[ -n "${TERMINAL_PROFILE_PATH}" ]] && [[ -f "${TERMINAL_PROFILE_PATH}" ]]; then
    log "Importing Terminal profiles..."
    import_terminal_profile_for_user "${ADMIN_USERNAME}" "${TERMINAL_PROFILE_PATH}"
    check_success "Terminal profile import for admin user"

    if dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
      import_terminal_profile_for_user "${OPERATOR_USERNAME}" "${TERMINAL_PROFILE_PATH}"
      check_success "Terminal profile import for operator user"
    fi
  elif [[ -n "${TERMINAL_PROFILE_PATH}" ]]; then
    log "Terminal profile file not found: ${TERMINAL_PROFILE_PATH}"
  else
    log "No Terminal profile configured - skipping Terminal profile setup"
  fi

  # Import iTerm2 preferences
  if [[ "${USE_ITERM2:-false}" == "true" ]] && [[ -f "${ITERM2_PREFERENCES_PATH}" ]]; then
    log "Importing iTerm2 preferences..."
    import_iterm2_preferences_for_user "${ADMIN_USERNAME}" "${ITERM2_PREFERENCES_PATH}"
    check_success "iTerm2 preferences import for admin user"

    if dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
      import_iterm2_preferences_for_user "${OPERATOR_USERNAME}" "${ITERM2_PREFERENCES_PATH}"
      check_success "iTerm2 preferences import for operator user"
    fi
  elif [[ "${USE_ITERM2:-false}" == "true" ]] && [[ ! -f "${ITERM2_PREFERENCES_PATH}" ]]; then
    log "iTerm2 preferences file not found: ${ITERM2_PREFERENCES_PATH}"
  else
    log "iTerm2 not configured - skipping iTerm2 preferences setup"
  fi

  log "Terminal profile configuration completed"
}

# Main execution
main() {
  log "Starting terminal profile configuration module"

  configure_terminal_profiles

  # Simple completion message
  local error_count=${#COLLECTED_ERRORS[@]}

  if [[ ${error_count} -eq 0 ]]; then
    show_log "✅ Terminal profile configuration completed successfully"
    show_log "ℹ️  Restart Terminal and iTerm2 to see new profiles"
    return 0
  else
    show_log "❌ Terminal profile configuration completed with ${error_count} errors"
    return 1
  fi
}

# Execute main function
main "$@"
