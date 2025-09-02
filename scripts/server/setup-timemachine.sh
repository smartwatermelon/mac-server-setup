#!/usr/bin/env bash
#
# setup-timemachine.sh - Time Machine backup configuration module
#
# This script configures Time Machine backup with SMB destinations using credentials
# stored in the keychain. It handles URL configuration, credential retrieval,
# destination setup, and menu bar integration for both admin and operator users.
#
# Usage: ./setup-timemachine.sh [--force]
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

# Load common configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

# Secure credential retrieval function (from first-boot.sh)
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

# TIME MACHINE CONFIGURATION
#

# Configure Time Machine backup
set_section "Configuring Time Machine"

# Check if Time Machine URL configuration is available
TIMEMACHINE_CONFIG_FILE="${SETUP_DIR}/config/timemachine.conf"
if [[ -f "${TIMEMACHINE_CONFIG_FILE}" ]]; then
  # Source the Time Machine URL configuration
  # shellcheck source=/dev/null
  source "${TIMEMACHINE_CONFIG_FILE}"

  # Validate that TM_URL was sourced
  if [[ -z "${TM_URL:-}" ]]; then
    collect_warning "Time Machine URL not found in configuration file - skipping Time Machine setup"
  else
    log "Found Time Machine URL configuration: ${TM_URL}"

    # Load keychain manifest for service names
    manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
    if [[ -f "${manifest_file}" ]]; then
      # shellcheck source=/dev/null
      source "${manifest_file}"

      # Get TimeMachine credentials from keychain (stored as username:password)
      if [[ -n "${KEYCHAIN_TIMEMACHINE_SERVICE:-}" && -n "${KEYCHAIN_ACCOUNT:-}" ]] && tm_credentials=$(get_keychain_credential "${KEYCHAIN_TIMEMACHINE_SERVICE}" "${KEYCHAIN_ACCOUNT}"); then
        log "Retrieved TimeMachine credentials from keychain"

        # Parse username:password format
        TM_USERNAME="${tm_credentials%%:*}"
        TM_PASSWORD="${tm_credentials#*:}"

        if [[ -z "${TM_USERNAME}" || -z "${TM_PASSWORD}" || "${TM_USERNAME}" == "${TM_PASSWORD}" ]]; then
          collect_error "Invalid TimeMachine credential format in keychain - expected username:password"
        else
          log "Checking existing Time Machine configuration"

          # Check if Time Machine is already configured with our destination
          EXPECTED_URL="smb://${TM_USERNAME}@${TM_URL}"

          # Handle case where no destinations exist yet (tmutil destinationinfo fails)
          if EXISTING_DESTINATIONS=$(tmutil destinationinfo 2>/dev/null | grep "^URL" | awk '{print $3}'); then
            log "Found existing Time Machine destinations"
          else
            log "No existing Time Machine destinations found"
            EXISTING_DESTINATIONS=""
          fi

          # Escape special regex characters using bash parameter expansion
          ESCAPED_URL="${EXPECTED_URL//\./\\.}"
          ESCAPED_URL="${ESCAPED_URL//\//\\/}"

          if [[ -n "${EXISTING_DESTINATIONS}" ]] && echo "${EXISTING_DESTINATIONS}" | grep -q "${ESCAPED_URL}"; then
            show_log "✅ Time Machine already configured with destination: ${TM_URL}"

            # Add to menu bar
            log "Adding Time Machine to menu bar"
            defaults write com.apple.systemuiserver menuExtras -array-add "/System/Library/CoreServices/Menu Extras/TimeMachine.menu"
            NEED_SYSTEMUI_RESTART=true
            check_success "Time Machine menu bar addition"
            if [[ -n "${OPERATOR_USERNAME:-}" ]] && dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
              sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.systemuiserver menuExtras -array-add "/System/Library/CoreServices/Menu Extras/TimeMachine.menu"
              check_success "Time Machine menu bar addition for operator"
            fi
          else
            log "Configuring Time Machine destination: ${TM_URL}"
            # Construct the full SMB URL with credentials
            TIMEMACHINE_URL="smb://${TM_USERNAME}:${TM_PASSWORD}@${TM_URL#*://}"

            if sudo -p "[Time Machine] Enter password to set backup destination: " tmutil setdestination -a "${TIMEMACHINE_URL}"; then
              check_success "Time Machine destination configuration"

              log "Enabling Time Machine"
              if sudo -p "[Time Machine] Enter password to enable backups: " tmutil enable; then
                show_log "✅ Time Machine backup configured and enabled"
                check_success "Time Machine enable"

                # Add Time Machine to menu bar for admin user
                log "Adding Time Machine to menu bar"
                defaults write com.apple.systemuiserver menuExtras -array-add "/System/Library/CoreServices/Menu Extras/TimeMachine.menu"
                NEED_SYSTEMUI_RESTART=true
                check_success "Time Machine menu bar addition"
                if [[ -n "${OPERATOR_USERNAME:-}" ]] && dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
                  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.systemuiserver menuExtras -array-add "/System/Library/CoreServices/Menu Extras/TimeMachine.menu"
                  check_success "Time Machine menu bar addition for operator"
                fi
              else
                collect_error "Failed to enable Time Machine"
              fi
            else
              collect_error "Failed to set Time Machine destination"
            fi
          fi
        fi

        # Clear credentials from memory
        unset tm_credentials TM_USERNAME TM_PASSWORD TIMEMACHINE_URL
      else
        collect_warning "TimeMachine credentials not found in keychain - skipping Time Machine setup"
      fi
    else
      collect_warning "Keychain manifest not found - cannot retrieve TimeMachine credentials"
    fi
  fi
else
  log "Time Machine configuration file not found - skipping Time Machine setup"
fi

# Apply menu bar changes if needed
if [[ "${NEED_SYSTEMUI_RESTART:-false}" == true ]]; then
  log "Restarting SystemUIServer to apply menu bar changes"
  killall SystemUIServer
  check_success "SystemUIServer restart for menu bar updates"
fi

show_log "✅ Time Machine configuration module completed successfully"

exit 0
