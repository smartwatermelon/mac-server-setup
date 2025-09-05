#!/usr/bin/env bash
#
# setup-system-preferences.sh - System preferences configuration
#
# This script handles various system preference configurations for the
# Mac Mini server. It includes:
# - Fast User Switching configuration
# - Scroll direction setting
# - Screen saver password requirements
# - Security settings
# - Software updates (optional)
#
# Usage: ./setup-system-preferences.sh [--force] [--skip-update]
#   --force: Skip all confirmation prompts
#   --skip-update: Skip software updates
#
# Author: Claude
# Version: 1.0
# Created: 2025-09-05

# Exit on any error
set -euo pipefail

# Parse command line arguments
FORCE=false
SKIP_UPDATE=false

for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    --skip-update)
      SKIP_UPDATE=true
      shift
      ;;
    *)
      echo "Usage: $0 [--force] [--skip-update]"
      exit 1
      ;;
  esac
done

# Configuration loading with fallback to environment variable
if [[ -n "${SETUP_DIR:-}" ]]; then
  CONFIG_FILE="${SETUP_DIR}/config/config.conf"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SETUP_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"
  CONFIG_FILE="${SETUP_DIR}/config/config.conf"
fi

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "❌ Configuration file not found: ${CONFIG_FILE}"
  exit 1
fi

# Set derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

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
        exit 1
      fi
    fi
  fi
}

# Set up required variables with fallbacks
OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"

# Fast User Switching
section "Enabling Fast User Switching"
log "Configuring Fast User Switching for multi-user access"
sudo -p "[System setup] Enter password to enable multiple user sessions: " defaults write /Library/Preferences/.GlobalPreferences MultipleSessionEnabled -bool true
check_success "Fast User Switching configuration"

# Fast User Switching menu bar style and visibility
defaults write .GlobalPreferences userMenuExtraStyle -int 1                                                                                                     # username
sudo -p "[User setup] Enter password to configure operator menu style: " -iu "${OPERATOR_USERNAME}" defaults write .GlobalPreferences userMenuExtraStyle -int 1 # username
defaults -currentHost write com.apple.controlcenter UserSwitcher -int 2                                                                                         # menubar
sudo -iu "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.controlcenter UserSwitcher -int 2                                                         # menubar

# Fix scroll setting
section "Fix scroll setting"
log "Fixing Apple's default scroll setting"
defaults write -g com.apple.swipescrolldirection -bool false
sudo -p "[User setup] Enter password to configure operator scroll direction: " -iu "${OPERATOR_USERNAME}" defaults write -g com.apple.swipescrolldirection -bool false
check_success "Fix scroll setting"

# Configure screen saver password requirement
section "Configuring screen saver password requirement"
defaults -currentHost write com.apple.screensaver askForPassword -int 1
defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0
sudo -p "[Security setup] Enter password to configure operator screen saver security: " -u "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.screensaver askForPassword -int 1
sudo -u "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0
log "Enabled immediate password requirement after screen saver"

# Run software updates if not skipped
if [[ "${SKIP_UPDATE}" = false ]]; then
  section "Running Software Updates"
  show_log "Checking for software updates (this may take a while)"

  # Check for updates
  UPDATE_CHECK=$(softwareupdate -l)
  if echo "${UPDATE_CHECK}" | grep -q "No new software available"; then
    log "System is up to date"
  else
    log "Installing software updates in background mode"
    sudo -p "[System update] Enter password to install software updates: " softwareupdate -i -a --background
    check_success "Initiating background software update"
  fi
else
  log "Skipping software updates as requested"
fi

# Configure security settings
section "Configuring Security Settings"

# Disable automatic app downloads
defaults write com.apple.SoftwareUpdate AutomaticDownload -int 0
log "Disabled automatic app downloads"

show_log "✅ System preferences configuration completed"
