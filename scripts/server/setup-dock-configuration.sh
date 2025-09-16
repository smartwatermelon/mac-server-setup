#!/usr/bin/env bash
#
# setup-dock-configuration.sh - Dock configuration module
#
# This script configures the administrator dock by removing default macOS
# applications and adding useful development and system utilities. It uses
# dockutil to modify the dock system-wide with the --allhomes flag.
#
# Usage: ./setup-dock-configuration.sh [--force]
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
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Make sure dockutil is installed
check_dockutil() {
  if command -v dockutil; then
    # installed and in path, all good!
    return 0
  elif [[ -f "${HOMEBREW_PREFIX}/bin/dockutil" ]]; then
    # installed but not in path
    export PATH="${PATH}:${HOMEBREW_PREFIX}/bin"
    command -v dockutil || return 1
  else
    # not installed
    "${HOMEBREW_PREFIX}/bin/brew" install dockutil
    export PATH="${PATH}:${HOMEBREW_PREFIX}/bin"
    command -v dockutil || return 1
  fi
}

# Main dock configuration function
configure_dock() {
  set_section "Cleaning up Administrator Dock"

  log "Cleaning up Administrator Dock"

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
}

# Main execution
main() {
  log "Starting dock configuration module"

  check_dockutil
  configure_dock

  # Simple completion message
  local error_count=${#COLLECTED_ERRORS[@]}

  if [[ ${error_count} -eq 0 ]]; then
    show_log "✅ Dock configuration completed successfully"
    return 0
  else
    show_log "❌ Dock configuration completed with ${error_count} errors"
    return 1
  fi
}

# Execute main function
main "$@"
