#!/usr/bin/env bash
#
# setup-network.sh - Network configuration setup module
#
# This script configures WiFi network settings from configuration files.
#
# Usage: ./setup-network.sh [--force]
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

# Configuration variables
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIFI_CONFIG_FILE="${SETUP_DIR}/config/wifi_network.conf"

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
# WIFI NETWORK CONFIGURATION
#

set_section "WiFi Network Assessment and Configuration"
show_log "WiFi Network Assessment and Configuration; this may take a moment..."

# Detect active WiFi interface
WIFI_INTERFACE=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}' || echo "en0")
log "Using WiFi interface: ${WIFI_INTERFACE}"

# Check current network connectivity status
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
  log "Current network connectivity verified"

  # Get current WiFi network name
  CURRENT_NETWORK=$(networksetup -getairportnetwork "${WIFI_INTERFACE}" | sed 's/Current Wi-Fi Network: //' | tr -d '\n')
  if [[ "${CURRENT_NETWORK}" == "You are not associated with an AirPort network." ]]; then
    log "Not currently connected to WiFi"
  else
    log "Currently connected to WiFi network: ${CURRENT_NETWORK}"
  fi

  # Check for WiFi configuration file and offer to connect to specified network
  if [[ -f "${WIFI_CONFIG_FILE}" ]]; then
    log "Found WiFi configuration file at ${WIFI_CONFIG_FILE}"

    # Source the config file to get network settings
    # shellcheck source=/dev/null
    source "${WIFI_CONFIG_FILE}"

    if [[ -n "${WIFI_SSID:-}" ]] && [[ -n "${WIFI_PASSWORD:-}" ]]; then
      if [[ "${CURRENT_NETWORK}" != "${WIFI_SSID}" ]]; then
        log "Configured network (${WIFI_SSID}) differs from current network (${CURRENT_NETWORK})"

        if [[ "${FORCE}" = true ]] || {
          echo -n "Connect to configured WiFi network '${WIFI_SSID}'? (Y/n): "
          read -r -n 1 wifi_choice
          echo
          [[ -z "${wifi_choice}" ]] || [[ ${wifi_choice} =~ ^[Yy]$ ]]
        }; then
          log "Connecting to WiFi network: ${WIFI_SSID}"
          networksetup -setairportnetwork "${WIFI_INTERFACE}" "${WIFI_SSID}" "${WIFI_PASSWORD}"
          check_success "WiFi network connection to ${WIFI_SSID}"

          # Wait for connection and verify
          sleep 5
          if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            show_log "✅ WiFi connection to ${WIFI_SSID} successful"
          else
            show_log "⚠️ WiFi configured but network connectivity test failed"
          fi
        else
          log "WiFi network change skipped by user"
        fi
      else
        log "Already connected to configured network: ${WIFI_SSID}"
      fi
    else
      show_log "⚠️ WiFi config file found but missing WIFI_SSID or WIFI_PASSWORD"
    fi
  else
    log "No WiFi configuration file found at ${WIFI_CONFIG_FILE}"
  fi
else
  log "✅ WiFi already working - skipping configuration"
fi

show_log "✅ Network setup completed successfully"

exit 0
