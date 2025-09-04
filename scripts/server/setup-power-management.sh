#!/usr/bin/env bash
#
# setup-power-management.sh - Power management setup module
#
# This script configures power management settings for Mac Mini server use.
# It disables system sleep, configures display sleep, enables wake-on-network,
# and sets up automatic restart after power failure.
#
# Usage: ./setup-power-management.sh [--force]
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
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Set derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Set up logging
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"
mkdir -p "${LOG_DIR}"

# Logging functions
log() {
  mkdir -p "${LOG_DIR}"
  local timestamp no_newline=false
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

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

show_log() {
  local no_newline=false

  if [[ "$1" == "-n" ]]; then
    no_newline=true
    echo -n "$2"
    log -n "$2"
  else
    echo "$1"
    log "$1"
  fi
}

section() {
  log "====== $1 ======"
}

# Error collection system (uses exported variables from parent script)
collect_error() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  # Append to temporary file for cross-process collection (if available)
  if [[ -n "${SETUP_ERRORS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_ERRORS_FILE}"
  fi
}

# shellcheck disable=SC2329 # Function included for consistency across modules
collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "⚠️ ${clean_message}"
  # Append to temporary file for cross-process collection (if available)
  if [[ -n "${SETUP_WARNINGS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_WARNINGS_FILE}"
  fi
}

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

check_success() {
  if [[ $? -eq 0 ]]; then
    show_log "✅ $1"
  else
    collect_error "$1 failed"
    if [[ "${FORCE}" == false ]]; then
      read -p "Continue anyway? (y/N) " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# POWER MANAGEMENT CONFIGURATION
#

set_section "Configuring Power Management"
log "Setting power management for server use"

# Check current settings
CURRENT_SLEEP=$(pmset -g 2>/dev/null | grep -E "^[ ]*sleep" | awk '{print $2}' || echo "unknown")
CURRENT_DISPLAYSLEEP=$(pmset -g 2>/dev/null | grep -E "^[ ]*displaysleep" | awk '{print $2}' || echo "unknown")
CURRENT_DISKSLEEP=$(pmset -g 2>/dev/null | grep -E "^[ ]*disksleep" | awk '{print $2}' || echo "unknown")
CURRENT_WOMP=$(pmset -g 2>/dev/null | grep -E "^[ ]*womp" | awk '{print $2}' || echo "unknown")
CURRENT_AUTORESTART=$(pmset -g 2>/dev/null | grep -E "^[ ]*autorestart" | awk '{print $2}' || echo "unknown")

# Apply settings only if they differ from current
if [[ "${CURRENT_SLEEP}" != "0" ]]; then
  sudo -p "[Power management] Enter password to disable system sleep: " pmset -a sleep 0
  log "Disabled system sleep"
fi

if [[ "${CURRENT_DISPLAYSLEEP}" != "60" ]]; then
  sudo -p "[Power management] Enter password to configure display sleep: " pmset -a displaysleep 60 # Display sleeps after 1 hour
  log "Set display sleep to 60 minutes"
fi

if [[ "${CURRENT_DISKSLEEP}" != "0" ]]; then
  sudo -p "[Power management] Enter password to disable disk sleep: " pmset -a disksleep 0
  log "Disabled disk sleep"
fi

if [[ "${CURRENT_WOMP}" != "1" ]]; then
  sudo -p "[Power management] Enter password to enable wake on network: " pmset -a womp 1 # Enable wake on network access
  log "Enabled Wake on Network Access"
fi

if [[ "${CURRENT_AUTORESTART}" != "1" ]]; then
  sudo -p "[Power management] Enter password to enable auto-restart: " pmset -a autorestart 1 # Restart on power failure
  log "Enabled automatic restart after power failure"
fi

check_success "Power management configuration"

show_log "✅ Power management module completed successfully"

exit 0
