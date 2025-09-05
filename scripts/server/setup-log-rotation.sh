#!/usr/bin/env bash
#
# setup-log-rotation.sh - Log rotation configuration module
#
# This script configures log rotation using Homebrew's logrotate service.
# It installs logrotate configuration, sets proper permissions, and starts
# the service for automated log management.
#
# Usage: ./setup-log-rotation.sh [--force]
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

# Set derived variables
ADMIN_USERNAME=$(whoami)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Set Homebrew prefix based on architecture (more predictable than brew --prefix)
ARCH="$(arch)"
case "${ARCH}" in
  i386)
    HOMEBREW_PREFIX="/usr/local"
    ;;
  arm64)
    HOMEBREW_PREFIX="/opt/homebrew"
    ;;
  *)
    collect_error "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

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

# Main log rotation configuration function
configure_log_rotation() {
  set_section "Configuring Log Rotation"

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
    "${HOMEBREW_PREFIX}/bin/brew" services stop logrotate &>/dev/null || true
    if "${HOMEBREW_PREFIX}/bin/brew" services start logrotate; then
      check_success "Admin logrotate service start"
      log "✅ Admin logrotate service started - admin logs will be rotated automatically"
    else
      collect_error "Failed to start admin logrotate service - admin logs will not be rotated"
    fi
  else
    log "No logrotate configuration found - skipping log rotation setup"
  fi
}

# Main execution
main() {
  log "Starting log rotation configuration module"

  configure_log_rotation

  # Simple completion message
  local error_count=${#COLLECTED_ERRORS[@]}

  if [[ ${error_count} -eq 0 ]]; then
    show_log "✅ Log rotation configuration completed successfully"
    return 0
  else
    show_log "❌ Log rotation configuration completed with ${error_count} errors"
    return 1
  fi
}

# Execute main function
main "$@"
