#!/usr/bin/env bash
#
# setup-application-preparation.sh - Application setup directory and operator file preparation
#
# This script handles the preparation of application setup directories and files,
# including:
# - Creating and populating application setup directory structure
# - Copying configuration files and templates
# - Setting up operator account directories and scripts
# - Configuring operator LaunchAgents for first-login automation
#
# Usage: ./setup-application-preparation.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude
# Version: 1.0
# Created: 2025-09-05

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

# Determine script and setup directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(dirname "${SCRIPT_DIR}")" # Go up one level to reach scripts/
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  SERVER_NAME="MACMINI"
  OPERATOR_USERNAME="operator"
fi

# Set derived variables
ADMIN_USERNAME=$(whoami)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

export LOG_DIR
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# Local logging functions
log() {
  mkdir -p "${LOG_DIR}"
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

# Error and warning collection system
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
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

  # Normalize message to single line (replace newlines with spaces)
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  COLLECTED_ERRORS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to collect a warning (with immediate display)
collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line (replace newlines with spaces)
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "⚠️ ${clean_message}"
  COLLECTED_WARNINGS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
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

#
# APPLICATION SETUP PREPARATION
#

# Create application setup directory
set_section "Preparing Application Setup"
APP_SETUP_DIR="/Users/${ADMIN_USERNAME}/app-setup"

if [[ ! -d "${APP_SETUP_DIR}" ]]; then
  log "Creating application setup directory"
  mkdir -p "${APP_SETUP_DIR}"
  check_success "App setup directory creation"
fi

# Copy application setup directory preserving organized structure
if [[ -d "${SETUP_DIR}/app-setup" ]]; then
  log "Copying application setup directory with organized structure from ${SETUP_DIR}/app-setup"

  # Copy the entire app-setup directory structure
  cp -R "${SETUP_DIR}/app-setup/"* "${APP_SETUP_DIR}/" 2>/dev/null

  # Set proper permissions
  chmod +x "${APP_SETUP_DIR}/"*.sh 2>/dev/null
  chmod 600 "${APP_SETUP_DIR}/config/"*.conf 2>/dev/null || true
  chmod 755 "${APP_SETUP_DIR}/templates/"*.sh 2>/dev/null || true

  check_success "Application directory copy with organized structure"
else
  collect_warning "No application setup directory found in ${SETUP_DIR}/app-setup"
fi

# Script templates are now copied above as part of the organized directory structure

# Copy config.conf for application setup scripts
if [[ -f "${CONFIG_FILE}" ]]; then
  log "Copying config.conf to app-setup config directory"
  mkdir -p "${APP_SETUP_DIR}/config"
  cp "${CONFIG_FILE}" "${APP_SETUP_DIR}/config/config.conf"
  check_success "Config file copy"
else
  collect_warning "No config.conf found - application setup scripts will use defaults"
fi

# Copy Dropbox configuration files if available (already copied above from app-setup/config)
# These files are now handled in the "Copy application config files" section above
log "Dropbox and rclone config files are copied from app-setup/config/ directory above"

# Setup operator account files
section "Configuring operator account files"
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
OPERATOR_CONFIG_DIR="${OPERATOR_HOME}/.config/operator"
OPERATOR_BIN_DIR="${OPERATOR_HOME}/.local/bin"

if [[ -f "${CONFIG_FILE}" ]]; then
  log "Setting up operator configuration directory"
  sudo -p "[Operator setup] Enter password to create operator config directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_CONFIG_DIR}"
  sudo -p "[Operator setup] Enter password to copy config.conf for operator: " cp "${CONFIG_FILE}" "${OPERATOR_CONFIG_DIR}/config.conf"
  sudo -p "[Operator setup] Enter password to set config ownership: " chown "${OPERATOR_USERNAME}:staff" "${OPERATOR_CONFIG_DIR}/config.conf"
  check_success "Operator config.conf copy"
fi

if [[ -f "${SETUP_DIR}/scripts/operator-first-login.sh" ]]; then
  log "Setting up operator first-login script"
  sudo -p "[Operator setup] Enter password to create operator bin directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_BIN_DIR}"
  sudo -p "[Operator setup] Enter password to copy first-login script: " cp "${SETUP_DIR}/scripts/operator-first-login.sh" "${OPERATOR_BIN_DIR}/"
  sudo -p "[Operator setup] Enter password to set script ownership and permissions: " chown "${OPERATOR_USERNAME}:staff" "${OPERATOR_BIN_DIR}/operator-first-login.sh"
  sudo -p "[Operator setup] Enter password to make first-login script executable: " chmod 755 "${OPERATOR_BIN_DIR}/operator-first-login.sh"
  check_success "Operator first-login script setup"

  # Add ~/.local/bin to operator's PATH in bash configuration
  OPERATOR_BASHRC="${OPERATOR_HOME}/.bashrc"
  if ! sudo -u "${OPERATOR_USERNAME}" test -f "${OPERATOR_BASHRC}" || ! sudo -u "${OPERATOR_USERNAME}" grep -q '/.local/bin' "${OPERATOR_BASHRC}"; then
    log "Adding ~/.local/bin to operator's PATH"
    sudo -p "[Operator setup] Enter password to configure operator PATH: " tee -a "${OPERATOR_BASHRC}" >/dev/null <<EOF

# Add user local bin to PATH
export PATH="\$HOME/.local/bin:\$PATH"
EOF
    sudo -p "[Operator setup] Enter password to set bashrc ownership: " chown "${OPERATOR_USERNAME}:staff" "${OPERATOR_BASHRC}"
    check_success "Operator PATH configuration"
  fi

  # Create LaunchAgent for one-time execution on operator login
  log "Setting up operator first-login LaunchAgent"
  OPERATOR_AGENTS_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
  OPERATOR_PLIST_NAME="com.${HOSTNAME_LOWER}.operator-first-login"
  OPERATOR_PLIST="${OPERATOR_AGENTS_DIR}/${OPERATOR_PLIST_NAME}.plist"

  sudo -p "[Operator setup] Enter password to create operator LaunchAgent directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_AGENTS_DIR}"

  sudo -p "[Operator setup] Enter password to create operator first-login LaunchAgent: " -u "${OPERATOR_USERNAME}" tee "${OPERATOR_PLIST}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${OPERATOR_PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OPERATOR_BIN_DIR}/operator-first-login.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${OPERATOR_HOME}/.local/state/${OPERATOR_PLIST_NAME}.log</string>
    <key>StandardErrorPath</key>
    <string>${OPERATOR_HOME}/.local/state/${OPERATOR_PLIST_NAME}.log</string>
</dict>
</plist>
EOF

  sudo -p "[Operator setup] Enter password to set LaunchAgent permissions: " -u "${OPERATOR_USERNAME}" chmod 644 "${OPERATOR_PLIST}"

  # Validate plist syntax
  if sudo -u "${OPERATOR_USERNAME}" plutil -lint "${OPERATOR_PLIST}" >/dev/null 2>&1; then
    log "LaunchAgent plist syntax validated successfully"
  else
    collect_error "Invalid plist syntax in ${OPERATOR_PLIST}"
    return 1
  fi

  check_success "Operator first-login LaunchAgent setup"
else
  collect_warning "No operator-first-login.sh found in ${SETUP_DIR}/scripts/"
fi

show_log "✅ Application preparation setup completed successfully"
show_log "Application setup directory: ${APP_SETUP_DIR}"
show_log "Operator configuration: ${OPERATOR_CONFIG_DIR}"
show_log "Operator scripts: ${OPERATOR_BIN_DIR}"

exit 0
