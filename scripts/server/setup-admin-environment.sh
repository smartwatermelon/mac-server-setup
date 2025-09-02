#!/usr/bin/env bash
#
# setup-admin-environment.sh - Administrator environment configuration module
#
# This script configures the administrator's environment including shell settings,
# dock customization, log rotation, and application setup preparation.
#
# Usage: ./setup-admin-environment.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude (modularized from first-boot.sh)
# Version: 1.0
# Created: 2025-09-02

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

# Set up logging
export LOG_DIR
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
current_hostname="$(hostname)"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${current_hostname}")"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# log function - only writes to log file
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

# show_log function - shows output to user and logs
show_log() {
  echo "$1"
  log "$1"
}

# section function - shows section header and logs
section() {
  show_log ""
  show_log "=== $1 ==="
}

# Error and warning collection (simplified for module)
declare -a collected_errors
declare -a collected_warnings
current_section=""

set_section() {
  current_section="$1"
}

collect_error() {
  local error_msg="$1"
  collected_errors+=("${current_section:+[${current_section}] }${error_msg}")
  show_log "❌ ERROR: ${error_msg}"
}

collect_warning() {
  local warning_msg="$1"
  collected_warnings+=("${current_section:+[${current_section}] }${warning_msg}")
  show_log "⚠️ WARNING: ${warning_msg}"
}

# check_success function
check_success() {
  local operation_name="$1"
  local exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    log "✅ ${operation_name}"
  else
    if [[ "${FORCE}" = true ]]; then
      collect_warning "${operation_name} failed but continuing due to --force flag"
    else
      collect_error "${operation_name} failed"
      show_log "❌ ${operation_name} failed (exit code: ${exit_code})"
      read -p "Continue anyway? (y/N): " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Configuration variables
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"
HOMEBREW_PREFIX="/opt/homebrew" # Apple Silicon

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  log "Loaded configuration from ${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  OPERATOR_USERNAME="operator"
fi

# Set derived variables
ADMIN_USERNAME=$(whoami)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME:-MACMINI}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

#
# ADMINISTRATOR ENVIRONMENT SETUP
#

#
# RELOAD PROFILE FOR CURRENT SESSION
#
section "Reload Profile"
# shellcheck source=/dev/null
source ~/.zprofile
check_success "Reload profile"

#
# CLEAN UP DOCK
#
section "Cleaning up Administrator Dock"
log "Cleaning up Administrator Dock"
if command -v dockutil &>/dev/null; then
  dockutil \
    --remove Messages \
    --remove Mail \
    --remove Maps \
    --remove Photos \
    --remove FaceTime \
    --remove Calendar \
    --remove Contacts \
    --remove Reminders \
    --remove Freeform \
    --remove TV \
    --remove Music \
    --remove News \
    --remove 'iPhone Mirroring' \
    --remove /System/Applications/Utilities/Terminal.app \
    --add /Applications/iTerm.app \
    --add /System/Applications/Passwords.app \
    --allhomes \
    &>/dev/null || true
  check_success "Administrator Dock cleaned up"
else
  log "Could not locate dockutil"
fi

# Note: Operator first-login setup is now handled automatically via LaunchAgent
# See the "Configuring operator account files" section above

#
# CHANGE DEFAULT SHELL TO HOMEBREW BASH
#
section "Changing Default Shell to Homebrew Bash"

# Get the Homebrew bash path
HOMEBREW_BASH="$(brew --prefix)/bin/bash"

if [[ -f "${HOMEBREW_BASH}" ]]; then
  log "Found Homebrew bash at: ${HOMEBREW_BASH}"

  # Add to /etc/shells if not already present
  if ! grep -q "${HOMEBREW_BASH}" /etc/shells; then
    log "Adding Homebrew bash to /etc/shells"
    echo "${HOMEBREW_BASH}" | sudo -p "[Shell setup] Enter password to add Homebrew bash to allowed shells: " tee -a /etc/shells
    check_success "Add Homebrew bash to /etc/shells"
  else
    log "Homebrew bash already in /etc/shells"
  fi

  # Change shell for admin user to Homebrew bash
  log "Setting shell to Homebrew bash for admin user"
  sudo -p "[Shell setup] Enter password to change admin shell: " chsh -s "${HOMEBREW_BASH}" "${ADMIN_USERNAME}"
  check_success "Admin user shell change"

  # Change shell for operator user if it exists
  if dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
    log "Setting shell to Homebrew bash for operator user"
    sudo -p "[Shell setup] Enter password to change operator shell: " chsh -s "${HOMEBREW_BASH}" "${OPERATOR_USERNAME}"
    check_success "Operator user shell change"
  fi

  # Copy .zprofile to .profile for bash compatibility
  log "Setting up bash profile compatibility"
  if [[ -f "/Users/${ADMIN_USERNAME}/.zprofile" ]]; then
    log "Copying admin .zprofile to .profile for bash compatibility"
    cp "/Users/${ADMIN_USERNAME}/.zprofile" "/Users/${ADMIN_USERNAME}/.profile"
  fi

  if dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
    log "Copying operator .zprofile to .profile for bash compatibility"
    sudo -p "[Shell setup] Enter password to copy operator profile: " cp "/Users/${OPERATOR_USERNAME}/.zprofile" "/Users/${OPERATOR_USERNAME}/.profile" 2>/dev/null || true
    sudo chown "${OPERATOR_USERNAME}:staff" "/Users/${OPERATOR_USERNAME}/.profile" 2>/dev/null || true
  fi

  check_success "Bash profile compatibility setup"
else
  log "Homebrew bash not found - skipping shell change"
fi

#
# LOG ROTATION SETUP
#
section "Configuring Log Rotation"

# Copy logrotate configuration if available
if [[ -f "${CONFIG_FILE%/*}/logrotate.conf" ]]; then
  log "Installing logrotate configuration"

  # Ensure logrotate config directory exists
  LOGROTATE_CONFIG_DIR="${HOMEBREW_PREFIX}/etc"
  if [[ ! -d "${LOGROTATE_CONFIG_DIR}" ]]; then
    sudo -p "[Logrotate setup] Enter password to create logrotate config directory: " mkdir -p "${LOGROTATE_CONFIG_DIR}"
  fi

  # Create logrotate.d include directory
  if [[ ! -d "${LOGROTATE_CONFIG_DIR}/logrotate.d" ]]; then
    sudo -p "[Logrotate setup] Enter password to create logrotate.d directory: " mkdir -p "${LOGROTATE_CONFIG_DIR}/logrotate.d"
  fi

  # Copy our logrotate configuration
  sudo -p "[Logrotate setup] Enter password to install logrotate config: " cp "${CONFIG_FILE%/*}/logrotate.conf" "${LOGROTATE_CONFIG_DIR}/"

  # Make config user-writable so both admin and operator can modify it (664)
  sudo -p "[Logrotate setup] Enter password to set config permissions: " chmod 664 "${LOGROTATE_CONFIG_DIR}/logrotate.conf"
  sudo -p "[Logrotate setup] Enter password to set config ownership: " chown "${ADMIN_USERNAME}:admin" "${LOGROTATE_CONFIG_DIR}/logrotate.conf"
  check_success "Logrotate configuration install"

  # Start logrotate service as admin user
  log "Starting logrotate service for admin user"
  brew services stop logrotate &>/dev/null || true
  if brew services start logrotate; then
    check_success "Admin logrotate service start"
    log "✅ Admin logrotate service started - admin logs will be rotated automatically"
  else
    log "⚠️  Failed to start admin logrotate service - admin logs will not be rotated"
  fi
else
  log "No logrotate configuration found - skipping log rotation setup"
fi

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
  log "No application setup directory found in ${SETUP_DIR}/app-setup"
fi

# Copy config.conf for application setup scripts
if [[ -f "${CONFIG_FILE}" ]]; then
  log "Copying config.conf to app-setup config directory"
  mkdir -p "${APP_SETUP_DIR}/config"
  cp "${CONFIG_FILE}" "${APP_SETUP_DIR}/config/config.conf"
  check_success "Config file copy"
else
  log "No config.conf found - application setup scripts will use defaults"
fi

# Copy Dropbox configuration files if available (already copied above from app-setup/config)
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
  if ! sudo -iu "${OPERATOR_USERNAME}" test -f "${OPERATOR_BASHRC}" || ! sudo -iu "${OPERATOR_USERNAME}" grep -q '/.local/bin' "${OPERATOR_BASHRC}"; then
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

  check_success "Operator first-login LaunchAgent creation"
  show_log "✅ Operator first-login will run automatically on next operator login"
fi

show_log "✅ Administrator environment configuration completed successfully"
