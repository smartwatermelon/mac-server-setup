#!/usr/bin/env bash
#
# setup-wifi-network.sh - WiFi network configuration module
#
# This script handles WiFi network assessment, configuration, and connectivity testing.
# It includes keychain integration for password storage, connectivity validation,
# and fallback to manual configuration when needed.
#
# Usage: ./setup-wifi-network.sh [--force]
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
WIFI_CONFIG_FILE="${SETUP_DIR}/config/wifi_network.conf"

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
WIFI_CONFIG_FILE="${SETUP_DIR}/config/wifi_network.conf"

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

# Secure credential retrieval function
get_keychain_credential() {
  local service="$1"
  local account="$2"

  local credential
  if credential=$(security find-generic-password \
    -s "${service}" \
    -a "${account}" \
    -w 2>/dev/null); then
    echo "${credential}"
    return 0
  else
    collect_error "Failed to retrieve credential from Keychain: ${service}"
    return 1
  fi
}

# WIFI NETWORK CONFIGURATION
#

set_section "WiFi Network Assessment and Configuration"
show_log "WiFi Network Assessment and Configuration; this may take a moment..."

# Detect active WiFi interface
WIFI_INTERFACE=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}' || echo "en0")
log "Using WiFi interface: ${WIFI_INTERFACE}"

# Check current network connectivity status
WIFI_CONFIGURED=false
CURRENT_NETWORK=$(system_profiler SPAirPortDataType -detailLevel basic | awk '/Current Network/ {getline;$1=$1;print $0 | "tr -d \":\"";exit}')

if [[ -n "${CURRENT_NETWORK}" ]]; then
  log "Connected to WiFi network: ${CURRENT_NETWORK}"

  # Test actual internet connectivity
  log "Testing internet connectivity..."
  if ping -c 1 -W 3000 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 3000 1.1.1.1 >/dev/null 2>&1; then
    show_log "✅ WiFi already configured and working: ${CURRENT_NETWORK}"
    WIFI_CONFIGURED=true
  else
    log "⚠️ Connected to WiFi but no internet access detected"
  fi
else
  log "No WiFi network currently connected"
fi

# Only attempt WiFi configuration if not already working
if [[ "${WIFI_CONFIGURED}" != true ]] && [[ -f "${WIFI_CONFIG_FILE}" ]]; then
  log "Found WiFi configuration file - attempting setup"

  # Source the WiFi configuration file to get SSID
  # shellcheck source=/dev/null
  source "${WIFI_CONFIG_FILE}"

  # Retrieve WiFi password from Keychain (if available)
  wifi_password=""
  if [[ -n "${KEYCHAIN_WIFI_SERVICE:-}" ]] && [[ -n "${KEYCHAIN_ACCOUNT:-}" ]]; then
    log "Attempting to retrieve WiFi password from Keychain..."
    if wifi_password=$(get_keychain_credential "${KEYCHAIN_WIFI_SERVICE}" "${KEYCHAIN_ACCOUNT}" 2>/dev/null); then
      # Extract password from combined credential (format: "ssid:password")
      wifi_password="${wifi_password#*:}"
      log "✅ WiFi password retrieved from Keychain"
    else
      log "⚠️ WiFi password not found in Keychain - manual configuration will be needed"
    fi
  fi

  if [[ -n "${WIFI_SSID}" ]] && [[ -n "${wifi_password}" ]]; then
    log "Configuring WiFi network: ${WIFI_SSID}"

    # Check if SSID is already in preferred networks list
    if networksetup -listpreferredwirelessnetworks "${WIFI_INTERFACE}" 2>/dev/null | grep -q "${WIFI_SSID}"; then
      log "WiFi network ${WIFI_SSID} is already in preferred networks list"
    else
      # Add WiFi network to preferred networks
      networksetup -addpreferredwirelessnetworkatindex "${WIFI_INTERFACE}" "${WIFI_SSID}" 0 WPA2
      check_success "Add preferred WiFi network"
      security add-generic-password -D "AirPort network password" -a "${WIFI_SSID}" -s "AirPort" -w "${wifi_password}" || true
      check_success "Store password in keychain"
    fi

    # Try to join the network
    log "Attempting to join WiFi network ${WIFI_SSID}..."
    networksetup -setairportnetwork "${WIFI_INTERFACE}" "${WIFI_SSID}" "${wifi_password}" &>/dev/null || true

    # Give it a few seconds and check if we connected
    sleep 5
    NEW_CONNECTION=$(system_profiler SPAirPortDataType -detailLevel basic | awk '/Current Network/ {getline;$1=$1;print $0 | "tr -d \":\"";exit}')
    if [[ "${NEW_CONNECTION}" == "${WIFI_SSID}" ]]; then
      show_log "✅ Successfully connected to WiFi network: ${WIFI_SSID}"
    else
      show_log "⚠️ WiFi network will be automatically joined after reboot"
    fi

    # Clear password from memory for security
    unset wifi_password
    log "WiFi password cleared from memory for security"
  else
    log "WiFi configuration file does not contain valid SSID and password"
  fi
elif [[ "${WIFI_CONFIGURED}" != true ]]; then
  log "No WiFi configuration available and no working connection detected"
  show_log "⚠️ Manual WiFi configuration required"
  show_log "Opening System Settings WiFi section..."

  # Open WiFi settings in System Settings
  open "x-apple.systempreferences:com.apple.wifi-settings-extension"

  if [[ "${FORCE}" = false ]]; then
    show_log "Please configure WiFi in System Settings, then press any key to continue..."
    read -p "Press any key when WiFi is configured... " -n 1 -r
    echo

    # Close System Settings now that user is done with WiFi configuration
    show_log "Closing System Settings..."
    osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true
  else
    show_log "Force mode: continuing without WiFi - may affect subsequent steps"
  fi
else
  log "✅ WiFi already working - skipping configuration"
fi

show_log "✅ WiFi network module completed successfully"

exit 0
