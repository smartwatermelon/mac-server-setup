#!/usr/bin/env bash
#
# setup-shell-configuration.sh - Shell configuration module
#
# This script changes the default shell to Homebrew bash for both admin and
# operator users. It adds Homebrew bash to /etc/shells, updates user shells,
# and sets up profile compatibility for bash by copying .zprofile to .profile.
#
# Usage: ./setup-shell-configuration.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude (modularized from first-boot.sh)
# Version: 1.0
# Created: 2025-09-04

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

# HOMEBREW_PREFIX is set and exported by first-boot.sh based on architecture
if [[ -z "${HOMEBREW_PREFIX:-}" ]]; then
  echo "Error: HOMEBREW_PREFIX not set - this script must be run from first-boot.sh"
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

# Main shell configuration function
configure_shell() {
  set_section "Changing Default Shell to Homebrew Bash"

  HOMEBREW_BASH="${HOMEBREW_PREFIX}/bin/bash"

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
}

# Main execution
main() {
  log "Starting shell configuration module"

  configure_shell

  # Simple completion message
  local error_count=${#COLLECTED_ERRORS[@]}

  if [[ ${error_count} -eq 0 ]]; then
    show_log "✅ Shell configuration completed successfully"
    return 0
  else
    show_log "❌ Shell configuration completed with ${error_count} errors"
    return 1
  fi
}

# Execute main function
main "$@"
