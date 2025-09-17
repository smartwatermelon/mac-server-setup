#!/usr/bin/env bash
#
# setup-hostname-volume.sh - Hostname and volume configuration module
#
# This script configures system hostname and renames the HD volume to match.
# It handles both computer name and local hostname settings for proper network
# identification and volume naming consistency.
#
# Usage: ./setup-hostname-volume.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Andrew Rich <andrew.rich@gmail.com> (modularized from first-boot.sh)
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

# HOSTNAME CONFIGURATION
#

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

# VOLUME RENAMING
#

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

show_log "✅ Hostname and volume module completed successfully"

exit 0
