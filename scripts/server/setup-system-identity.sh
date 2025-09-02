#!/usr/bin/env bash
#
# setup-system-identity.sh - System hostname and volume naming module
#
# This script configures system hostname and volume name based on configuration.
#
# Usage: ./setup-system-identity.sh [--force]
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

# Function to set current script section for context
set_section() {
  section "$1"
}

# Function to check if a command was successful
check_success() {
  if [[ $? -eq 0 ]]; then
    show_log "✅ $1"
  else
    show_log "❌ $1 failed"
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

# Configuration variables
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  log "Loaded configuration from ${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  SERVER_NAME="MACMINI"
fi

# Set derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"

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

#
# SYSTEM IDENTITY SETUP
#

# Set hostname and HD name
set_section "Setting Hostname and HD volume name"
CURRENT_HOSTNAME=$(hostname)
if [[ "${CURRENT_HOSTNAME}" = "${HOSTNAME}" ]]; then
  log "Hostname is already set to ${HOSTNAME}"
else
  log "Setting hostname to ${HOSTNAME}"
  sudo -p "[System setup] Enter password to set computer hostname: " scutil --set ComputerName "${HOSTNAME}"
  sudo -p "[System setup] Enter password to set local hostname: " scutil --set LocalHostName "${HOSTNAME}"
  sudo -p "[System setup] Enter password to set system hostname: " scutil --set HostName "${HOSTNAME}"
  check_success "Hostname configuration"
fi
log "Renaming HD"

# Create a temporary file for the plist output
TEMP_PLIST=$(mktemp)
if diskutil info -plist / >"${TEMP_PLIST}"; then
  CURRENT_VOLUME=$(/usr/libexec/PlistBuddy -c "Print :VolumeName" "${TEMP_PLIST}" 2>/dev/null || echo "Macintosh HD")
else
  CURRENT_VOLUME="Macintosh HD"
fi

# Clean up temp file
rm -f "${TEMP_PLIST}"

# Only rename if the volume name is different
if [[ "${CURRENT_VOLUME}" != "${HOSTNAME}" ]]; then
  log "Current volume name: ${CURRENT_VOLUME}"
  log "Renaming volume from '${CURRENT_VOLUME}' to '${HOSTNAME}'"
  diskutil rename "/Volumes/${CURRENT_VOLUME}" "${HOSTNAME}"
  check_success "Renamed HD from '${CURRENT_VOLUME}' to '${HOSTNAME}'"
else
  log "Volume is already named '${HOSTNAME}'"
fi

show_log "✅ System identity setup completed successfully"

exit 0
