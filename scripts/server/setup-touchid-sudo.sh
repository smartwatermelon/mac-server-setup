#!/usr/bin/env bash
#
# setup-touchid-sudo.sh - TouchID sudo authentication setup module
#
# This script configures TouchID authentication for sudo commands and sets
# appropriate sudo timeout for smooth setup operations.
#
# Usage: ./setup-touchid-sudo.sh [--force]
#   --force: Skip all confirmation prompts and enable TouchID by default
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

# Set up logging (ensure LOG_DIR is available)
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

# Error and warning collection functions for module context
# These write to temporary files shared with first-boot.sh
collect_error() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  # Append to shared temporary file (exported from first-boot.sh)
  if [[ -n "${SETUP_ERRORS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_ERRORS_FILE}"
  fi
}

collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "⚠️ ${clean_message}"
  # Append to shared temporary file (exported from first-boot.sh)
  if [[ -n "${SETUP_WARNINGS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_WARNINGS_FILE}"
  fi
}

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

# Function to check if a command was successful
check_success() {
  local operation_name="$1"
  local exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    show_log "✅ ${operation_name}"
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

#
# TOUCHID SUDO SETUP
#

# TouchID sudo setup
set_section "TouchID sudo setup"

# Check if TouchID sudo is already configured
if [[ -f "/etc/pam.d/sudo_local" ]]; then
  # Verify the content is correct
  expected_content="auth       sufficient     pam_tid.so"
  if grep -q "${expected_content}" "/etc/pam.d/sudo_local" 2>/dev/null; then
    show_log "✅ TouchID sudo is already properly configured"
  else
    log "TouchID sudo configuration exists but content may be incorrect"
    log "Current content:"
    head -10 <"/etc/pam.d/sudo_local" | while read -r line; do log "  ${line}"; done
  fi
else
  # TouchID sudo not configured - prompt user
  touchid_enabled=false

  if [[ "${FORCE}" = true ]]; then
    # Force mode - enable TouchID by default
    touchid_enabled=true
    log "Force mode enabled - configuring TouchID sudo authentication"
  else
    # Interactive mode - prompt user
    show_log "TouchID sudo allows you to use fingerprint authentication for administrative commands."
    show_log "This is more convenient than typing your password repeatedly."

    read -p "Enable TouchID for sudo authentication? (Y/n): " -n 1 -r touchid_choice
    echo

    if [[ -z "${touchid_choice}" ]] || [[ ${touchid_choice} =~ ^[Yy]$ ]]; then
      touchid_enabled=true
    else
      log "TouchID sudo setup skipped - standard password authentication will be used"
    fi
  fi

  if [[ "${touchid_enabled}" = true ]]; then
    # Check if TouchID is available before warning about password
    if bioutil -rs 2>/dev/null | grep -q "Touch ID"; then
      show_log "TouchID sudo needs to be configured. We will ask for your user password."
    else
      show_log "TouchID sudo needs to be configured (TouchID not available - will use password)."
    fi

    # Create the PAM configuration file
    log "Creating TouchID sudo configuration..."
    sudo -p "[TouchID setup] Enter password to configure TouchID for sudo: " tee "/etc/pam.d/sudo_local" >/dev/null <<'EOF'
# sudo_local: PAM configuration for enabling TouchID for sudo
#
# This file enables the use of TouchID as an authentication method for sudo
# commands on macOS. It is used in addition to the standard sudo configuration.
#
# Format: auth sufficient pam_tid.so

# Allow TouchID authentication for sudo
auth       sufficient     pam_tid.so
EOF
    check_success "TouchID sudo configuration"

    # Test TouchID configuration
    log "Testing TouchID sudo configuration..."
    sudo -p "[TouchID test] Enter password to test TouchID sudo configuration: " -v
    check_success "TouchID sudo test"
  fi
fi

# Configure sudo timeout to reduce password prompts during setup
set_section "Configuring sudo timeout"
show_log "Setting sudo timeout to 30 minutes for smoother setup experience"
sudo -p "[System setup] Enter password to configure sudo timeout: " tee /etc/sudoers.d/10_setup_timeout >/dev/null <<EOF
# Temporary sudo timeout extension for setup - 30 minutes
Defaults timestamp_timeout=30
EOF
# Fix permissions for sudoers file
sudo chmod 0440 /etc/sudoers.d/10_setup_timeout
check_success "Sudo timeout configuration"

show_log "✅ TouchID sudo setup completed successfully"

exit 0
