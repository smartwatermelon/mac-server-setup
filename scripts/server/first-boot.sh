#!/usr/bin/env bash
#
# first-boot.sh - Complete setup script for Mac Mini server
#
# This script performs the complete setup for the Mac Mini server after
# the macOS setup wizard has been completed. It configures:
# - Remote management (SSH and Remote Desktop)
# - User accounts
# - System settings
# - Power management
# - Security configurations
# - Homebrew and packages installation
# - Application preparation
#
# Usage: ./first-boot.sh [--force] [--skip-update] [--skip-homebrew] [--skip-packages]
#   --force: Skip all confirmation prompts
#   --skip-update: Skip software updates (which can be time-consuming)
#   --skip-homebrew: Skip Homebrew installation/update
#   --skip-packages: Skip package installation
#
# Author: Claude
# Version: 2.2
# Created: 2025-05-18

# Exit on any error
set -euo pipefail

# Configuration variables - adjust as needed
ADMIN_USERNAME=$(whoami)                                  # Set this once and use throughout
ADMINISTRATOR_PASSWORD=""                                 # Get it interactively later
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Directory where AirDropped files are located (script now at root)
SSH_KEY_SOURCE="${SETUP_DIR}/ssh_keys"
WIFI_CONFIG_FILE="${SETUP_DIR}/config/wifi_network.conf"
FORMULAE_FILE="${SETUP_DIR}/config/formulae.txt"
CASKS_FILE="${SETUP_DIR}/config/casks.txt"
RERUN_AFTER_FDA=false
NEED_SYSTEMUI_RESTART=false
NEED_CONTROLCENTER_RESTART=false
# Safety: Development machine fingerprint (to prevent accidental execution)
DEV_FINGERPRINT_FILE="${SETUP_DIR}/config/dev_fingerprint.conf"
DEV_MACHINE_FINGERPRINT=""      # Default blank - will be populated from file
HOMEBREW_PREFIX="/opt/homebrew" # Apple Silicon

# Parse command line arguments
FORCE=false
SKIP_UPDATE=true # this is unreliable during setup
SKIP_HOMEBREW=false
SKIP_PACKAGES=false

for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    --skip-update)
      SKIP_UPDATE=true
      shift
      ;;
    --skip-homebrew)
      SKIP_HOMEBREW=true
      shift
      ;;
    --skip-packages)
      SKIP_PACKAGES=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Load configuration
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  echo "Loaded configuration from ${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  SERVER_NAME="MACMINI"
  OPERATOR_USERNAME="operator"
  ONEPASSWORD_VAULT="personal"
  ONEPASSWORD_OPERATOR_ITEM="operator"
fi

# Set derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
OPERATOR_FULLNAME="${SERVER_NAME} Operator"

export LOG_DIR
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# _timeout function - uses timeout utility if installed, otherwise Perl
# https://gist.github.com/jaytaylor/6527607
function _timeout() {
  if command -v timeout; then
    timeout "$@"
  else
    if ! command -v perl; then
      echo "perl not found 😿"
      exit 1
    else
      perl -e 'alarm shift; exec @ARGV' "$@"
    fi
  fi
}

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

# Error and warning collection system
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
CURRENT_SCRIPT_SECTION=""

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

# Function to collect an error (with immediate display)
collect_error() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line (replace newlines with spaces)
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  COLLECTED_ERRORS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to collect a warning (with immediate display)
collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line (replace newlines with spaces)
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "⚠️ ${clean_message}"
  COLLECTED_WARNINGS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to show collected errors and warnings at end
show_collected_issues() {
  local error_count=${#COLLECTED_ERRORS[@]}
  local warning_count=${#COLLECTED_WARNINGS[@]}

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    show_log "✅ Setup completed successfully with no errors or warnings!"
    return
  fi

  show_log ""
  show_log "====== SETUP SUMMARY ======"
  show_log "Setup completed, but ${error_count} errors and ${warning_count} warnings occurred:"
  show_log ""

  if [[ ${error_count} -gt 0 ]]; then
    show_log "ERRORS:"
    for error in "${COLLECTED_ERRORS[@]}"; do
      show_log "  ${error}"
    done
    show_log ""
  fi

  if [[ ${warning_count} -gt 0 ]]; then
    show_log "WARNINGS:"
    for warning in "${COLLECTED_WARNINGS[@]}"; do
      show_log "  ${warning}"
    done
    show_log ""
  fi

  show_log "Review the full log for details: ${LOG_FILE}"
}

# Deploy Package Manifest Validation
# Validates that all required files are present in the deployment package
# before beginning system setup operations

validate_deploy_package() {
  local manifest_file="${SETUP_DIR}/DEPLOY_MANIFEST.txt"
  local validation_errors=0
  local validation_warnings=0

  if [[ ! -f "${manifest_file}" ]]; then
    collect_error "Deploy manifest not found: ${manifest_file}"
    show_log "This deployment package was created with an older version of prep-airdrop.sh"
    show_log "Consider regenerating the package for better deployment validation"
    return 1
  fi

  log "Validating deployment package against manifest"

  # Parse manifest and check each file
  while read -r line || [[ -n "${line}" ]]; do
    # Skip comments and empty lines
    [[ "${line}" =~ ^#.*$ ]] || [[ -z "${line}" ]] && continue

    # Skip metadata entries
    [[ "${line}" =~ ^(MANIFEST_VERSION|CREATED_BY|CREATED_AT|PACKAGE_ROOT)= ]] && continue

    # Check if line contains an equals sign
    if [[ ! "${line}" =~ = ]]; then
      collect_warning "Malformed manifest entry (no equals sign): ${line}"
      ((validation_warnings += 1))
      continue
    fi

    # Parse file path and requirement safely
    file_path="${line%%=*}"  # Everything before first =
    requirement="${line#*=}" # Everything after first =

    # Handle edge cases
    if [[ -z "${file_path}" ]]; then
      collect_warning "Malformed manifest entry (empty file path): ${line}"
      ((validation_warnings += 1))
      continue
    fi

    if [[ -z "${requirement}" ]]; then
      collect_warning "Malformed manifest entry (empty requirement): ${line}"
      ((validation_warnings += 1))
      continue
    fi

    local full_path="${SETUP_DIR}/${file_path}"

    if [[ -f "${full_path}" ]]; then
      log "✅ Found: ${file_path}"
    else
      case "${requirement}" in
        "REQUIRED")
          collect_error "Required file missing from deploy package: ${file_path}"
          ((validation_errors += 1))
          ;;
        "OPTIONAL")
          collect_warning "Optional file missing from deploy package: ${file_path}"
          ((validation_warnings += 1))
          ;;
        "MISSING")
          log "📋 Expected missing: ${file_path} (was not available during package creation)"
          ;;
        *)
          collect_warning "Unknown requirement '${requirement}' for file: ${file_path}"
          ((validation_warnings += 1))
          ;;
      esac
    fi
  done <"${manifest_file}"

  if [[ ${validation_errors} -gt 0 ]]; then
    collect_error "Deploy package validation failed: ${validation_errors} required files missing"
    show_log "❌ Cannot proceed with setup - required files are missing from deployment package"
    show_log "Please regenerate the deployment package with prep-airdrop.sh and try again"
    return 1
  fi

  if [[ ${validation_warnings} -gt 0 ]]; then
    show_log "Deploy package validation completed with ${validation_warnings} optional files missing"
    show_log "Setup will continue, but some optional features may not be available"
  else
    show_log "✅ Deploy package validation passed - all files present"
  fi

  return 0
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

# Keychain credential management functions
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

# Import credentials from external keychain and populate user keychains
import_external_keychain_credentials() {

  set_section "Importing Credentials from External Keychain"
  # Load keychain manifest
  local manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
  if [[ ! -f "${manifest_file}" ]]; then
    collect_error "Keychain manifest not found: ${manifest_file}"
    return 1
  fi

  # shellcheck source=/dev/null
  source "${manifest_file}"

  # Validate required variables from manifest
  if [[ -z "${KEYCHAIN_PASSWORD:-}" || -z "${EXTERNAL_KEYCHAIN:-}" ]]; then
    collect_error "Required keychain variables not found in manifest"
    return 1
  fi

  # Copy external keychain file to user's keychain directory (preserve original for idempotency)
  local external_keychain_file="${SETUP_DIR}/config/${EXTERNAL_KEYCHAIN}-db"
  local user_keychain_file="${HOME}/Library/Keychains/${EXTERNAL_KEYCHAIN}-db"

  if [[ ! -f "${external_keychain_file}" ]]; then
    if [[ -f "${user_keychain_file}" ]]; then
      log "External keychain file not found in setup package, but located in local keychains."
      cp "${user_keychain_file}" "${external_keychain_file}"
    else
      collect_error "External keychain file not found: ${external_keychain_file}"
      return 1
    fi
  fi

  log "Copying external keychain to user's keychain directory..."
  cp "${external_keychain_file}" "${user_keychain_file}"
  chmod 600 "${user_keychain_file}"
  check_success "External keychain file copied"

  # Unlock external keychain
  log "Unlocking external keychain with dev machine fingerprint..."
  if security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${EXTERNAL_KEYCHAIN}"; then
    show_log "✅ External keychain unlocked successfully"
  else
    collect_error "Failed to unlock external keychain"
    return 1
  fi

  # Import administrator credentials to default keychain
  log "Importing administrator credentials to default keychain..."

  # Unlock admin keychain first
  show_log "Unlocking administrator keychain for credential import..."

  if ! security unlock-keychain -p "${ADMINISTRATOR_PASSWORD}"; then
    collect_error "Failed to unlock administrator keychain"
    return 1
  fi

  # Import operator credential
  # shellcheck disable=SC2154 # KEYCHAIN_OPERATOR_SERVICE loaded from sourced manifest
  if operator_password=$(security find-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    # Store in default keychain
    security delete-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${operator_password}" -D "Mac Server Setup - Operator Account Password" -A -U; then
      # Verify storage
      if compare_password=$(security find-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w 2>/dev/null); then
        if [[ "${operator_password}" == "${compare_password}" ]]; then
          show_log "✅ Operator credential imported to administrator keychain"
        else
          collect_error "Operator credential verification failed after import"
          return 1
        fi
      else
        collect_error "Operator credential import verification failed"
        return 1
      fi
    else
      collect_error "Failed to import operator credential to administrator keychain"
      return 1
    fi
    unset operator_password compare_password
  else
    collect_error "Failed to retrieve operator credential from external keychain"
    return 1
  fi

  # Import Plex NAS credential
  # shellcheck disable=SC2154 # KEYCHAIN_PLEX_NAS_SERVICE loaded from sourced manifest
  if plex_nas_credential=$(security find-generic-password -s "${KEYCHAIN_PLEX_NAS_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_PLEX_NAS_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_PLEX_NAS_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${plex_nas_credential}" -D "Mac Server Setup - Plex NAS Credentials" -A -U; then
      show_log "✅ Plex NAS credential imported to administrator keychain"
    else
      collect_error "Failed to import Plex NAS credential to administrator keychain"
      return 1
    fi
    unset plex_nas_credential
  else
    collect_warning "Plex NAS credential not found in external keychain (may be optional)"
  fi

  # Import TimeMachine credential (optional)
  # shellcheck disable=SC2154 # KEYCHAIN_TIMEMACHINE_SERVICE loaded from sourced manifest
  if timemachine_credential=$(security find-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${timemachine_credential}" -D "Mac Server Setup - TimeMachine Credentials" -A -U; then
      show_log "✅ TimeMachine credential imported to administrator keychain"
    else
      collect_warning "Failed to import TimeMachine credential to administrator keychain"
    fi
    unset timemachine_credential
  else
    show_log "⚠️ TimeMachine credential not found in external keychain (optional)"
  fi

  # Import WiFi credential (optional)
  if wifi_credential=$(security find-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${wifi_credential}" -D "Mac Server Setup - WiFi Credentials" -A -U; then
      show_log "✅ WiFi credential imported to administrator keychain"
    else
      collect_warning "Failed to import WiFi credential to administrator keychain"
    fi
    unset wifi_credential
  else
    show_log "⚠️ WiFi credential not found in external keychain (optional)"
  fi

  return 0
}

# SAFETY CHECK: Prevent execution on development machine
set_section "Development Machine Safety Check"

# Load development fingerprint if available
if [[ -f "${DEV_FINGERPRINT_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${DEV_FINGERPRINT_FILE}"
  log "Loaded development machine fingerprint for safety check"
else
  echo "❌ SAFETY ABORT: No development fingerprint file found"
  echo "This indicates the setup directory was not properly prepared with airdrop-prep.sh"
  exit 1
fi

# Abort if fingerprint is blank (safety default)
if [[ -z "${DEV_MACHINE_FINGERPRINT}" ]]; then
  echo "❌ SAFETY ABORT: Blank development machine fingerprint"
  echo "Setup directory appears corrupted or improperly prepared"
  exit 1
fi

# Check if running in a GUI session (required for many setup operations)
SESSION_TYPE=$(launchctl managername 2>/dev/null || echo "Unknown")
if [[ "${SESSION_TYPE}" != "Aqua" ]]; then
  echo "❌ ERROR: This script requires a GUI session to run properly"
  echo "Current session type: ${SESSION_TYPE}"
  echo ""
  echo "Mac Mini server setup requires desktop access for:"
  echo "- User account creation and configuration"
  echo "- System Settings modifications"
  echo "- AppleScript dialogs and automation"
  echo "- Application installations and setup"
  echo ""
  echo "Please run this script from the Mac's local desktop session."
  exit 1
fi
show_log "✓ GUI session detected (${SESSION_TYPE}) - setup can proceed"

# Get current machine fingerprint
CURRENT_FINGERPRINT=$(system_profiler SPHardwareDataType | grep "Hardware UUID" | awk '{print $3}')

# Abort if running on development machine
if [[ "${CURRENT_FINGERPRINT}" == "${DEV_MACHINE_FINGERPRINT}" ]]; then
  echo "❌ SAFETY ABORT: This script is running on the development machine"
  echo "Development fingerprint: ${DEV_MACHINE_FINGERPRINT}"
  echo "Current fingerprint: ${CURRENT_FINGERPRINT}"
  echo ""
  echo "This script is only for target Mac Mini server setup"
  exit 1
fi

show_log "✅ Safety check passed - not running on development machine"
log "Current machine: ${CURRENT_FINGERPRINT}"

# CRITICAL CHECK: FileVault compatibility for auto-login functionality
set_section "FileVault Compatibility Check"

log "Checking FileVault status (critical for auto-login functionality)..."

if ! command -v fdesetup >/dev/null 2>&1; then
  collect_warning "fdesetup not available, skipping FileVault check"
else
  filevault_status=$(fdesetup status 2>/dev/null || echo "unknown")

  if [[ "${filevault_status}" == *"FileVault is On"* ]]; then
    echo ""
    echo "=================================================================="
    echo "                    ⚠️  CRITICAL ISSUE DETECTED  ⚠️"
    echo "=================================================================="
    echo ""
    echo "FileVault disk encryption is ENABLED on this system."
    echo ""
    echo "This is incompatible with automatic login functionality,"
    echo "which is required for the operator account setup."
    echo ""
    echo "RESOLUTION OPTIONS:"
    echo "1. Try disabling FileVault via command line (fastest):"
    echo "   • Run: sudo fdesetup disable"
    echo "   • This requires decryption which may take several hours"
    echo "   • Then re-run this setup script"
    echo ""
    echo "2. Try disabling FileVault in System Settings:"
    echo "   • Open System Settings > Privacy & Security > FileVault"
    echo "   • Click 'Turn Off...' and follow the prompts"
    echo "   • This requires decryption which may take several hours"
    echo "   • Then re-run this setup script"
    echo ""
    echo "3. If FileVault cannot be disabled:"
    echo "   • Wipe this Mac completely and start over"
    echo "   • During macOS setup, DO NOT enable FileVault"
    echo "   • Ensure automatic login is enabled for admin account"
    echo ""
    echo "FileVault prevents automatic login for security reasons."
    echo "This Mac Mini server setup requires auto-login for the"
    echo "operator account to work properly."
    echo ""
    echo "=================================================================="
    echo ""

    collect_error "FileVault is enabled - incompatible with auto-login setup"

    if [[ "${FORCE}" != "true" ]]; then
      read -p "Would you like to disable FileVault now? (y/N): " -n 1 -r response
      echo
      case ${response} in
        [yY])
          show_log "Disabling FileVault - this may take 30-60+ minutes..."
          if sudo -p "[FileVault] Enter password to disable FileVault: " fdesetup disable; then
            show_log "✅ FileVault disabled successfully"
            show_log "Auto-login should now work properly"
          else
            collect_error "Failed to disable FileVault"
            show_log ""
            show_log "ALTERNATIVE OPTIONS (choose ONE):"
            show_log "1. System Settings > Privacy & Security > FileVault > Turn Off"
            show_log "2. Run 'sudo fdesetup disable' manually later"
            show_log "3. Perform clean system installation without FileVault"
          fi
          ;;
        *)
          show_log "FileVault remains enabled - setup will continue but auto-login may not work"
          collect_warning "User chose to continue with FileVault enabled"
          show_log ""
          show_log "ALTERNATIVE OPTIONS (choose ONE):"
          show_log "1. Disable via System Settings:"
          show_log "   • Open System Settings > Privacy & Security > FileVault"
          show_log "   • Click 'Turn Off...' and follow the prompts"
          show_log ""
          show_log "2. Disable via command line:"
          show_log "   • Run: sudo fdesetup disable"
          show_log ""
          show_log "3. If FileVault cannot be disabled:"
          show_log "   • Wipe this Mac completely and start over"
          show_log "   • During macOS setup, DO NOT enable FileVault"
          ;;
      esac
    else
      collect_warning "Force mode - continuing despite FileVault being enabled"
      show_log "Auto-login functionality will NOT work with FileVault enabled"
    fi

  elif [[ "${filevault_status}" == *"Deferred"* ]]; then
    echo ""
    echo "=================================================================="
    echo "                    ⚠️  POTENTIAL ISSUE DETECTED  ⚠️"
    echo "=================================================================="
    echo ""
    echo "FileVault has DEFERRED ENABLEMENT scheduled."
    echo "This means it will be enabled after the next reboot."
    echo ""
    echo "This will disable automatic login functionality required"
    echo "for the operator account."
    echo ""
    echo "RECOMMENDATION:"
    echo "Cancel FileVault enablement before it takes effect:"
    echo "  sudo fdesetup disable"
    echo ""
    echo "=================================================================="
    echo ""

    collect_warning "FileVault deferred enablement detected - will disable auto-login after reboot"

    if [[ "${FORCE}" != "true" ]]; then
      read -p "Continue with setup? (Y/n): " -n 1 -r response
      echo
      case ${response} in
        [nN])
          show_log "Setup cancelled to resolve FileVault deferred enablement"
          exit 1
          ;;
        *)
          show_log "Continuing setup - recommend disabling FileVault deferred enablement"
          ;;
      esac
    fi

  elif [[ "${filevault_status}" == *"FileVault is Off"* ]]; then
    show_log "✅ FileVault is disabled - automatic login will work properly"

  else
    collect_warning "FileVault status unclear: ${filevault_status}"
    show_log "Manual verification recommended for auto-login compatibility"
  fi
fi

# Create log file if it doesn't exist, rotate if it exists
if [[ -f "${LOG_FILE}" ]]; then
  # Rotate existing log file with timestamp
  ROTATED_LOG="${LOG_FILE%.log}-$(date +%Y%m%d-%H%M%S).log"
  mv "${LOG_FILE}" "${ROTATED_LOG}"
  log "Rotated previous log to: ${ROTATED_LOG}"
fi

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

# Function to check if a Terminal window with specific title exists
check_terminal_window_exists() {
  local window_title="$1"
  osascript -e "
    tell application \"Terminal\"
      set window_exists to false
      try
        repeat with w in windows
          if (name of w) contains \"${window_title}\" then
            set window_exists to true
            exit repeat
          end if
        end repeat
      end try
      return window_exists
    end tell
  " 2>/dev/null
}

# Tail log in separate window (only if one doesn't already exist)
window_exists=$(check_terminal_window_exists "Setup Log")
if [[ "${window_exists}" == "true" ]]; then
  log "Found existing Setup Log window - reusing it"
else
  log "Opening new Setup Log window"
  osascript -e 'tell application "Terminal" to do script "printf \"\\e]0;Setup Log\\a\"; tail -F '"${LOG_FILE}"'"' || echo "oops, no tail"
fi

# Print header
set_section "Starting Mac Mini '${SERVER_NAME}' Server Setup"
log "Running as user: ${ADMIN_USERNAME}"
timestamp="$(date)"
log "Date: ${timestamp}"
productversion="$(sw_vers -productVersion)"
log "macOS Version: ${productversion}"
log "Setup directory: ${SETUP_DIR}"

# Validate deployment package before beginning setup
set_section "Validating Deployment Package"
if ! validate_deploy_package; then
  show_log "❌ Deployment package validation failed - cannot proceed with setup"
  show_collected_issues
  exit 1
fi

# Look for evidence we're being re-run after FDA grant
if [[ -f "/tmp/${HOSTNAME_LOWER}_fda_requested" ]]; then
  RERUN_AFTER_FDA=true
  rm -f "/tmp/${HOSTNAME_LOWER}_fda_requested"
  log "Detected re-run after Full Disk Access grant"
fi

# Confirm operation if not forced
if [[ "${FORCE}" = false ]] && [[ "${RERUN_AFTER_FDA}" = false ]]; then
  read -p "This script will configure your Mac Mini server. Continue? (Y/n) " -n 1 -r
  echo
  # Default to Yes if Enter pressed (empty REPLY)
  if [[ -n "${REPLY}" ]] && [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

# Collect administrator password for keychain operations
if [[ "${FORCE}" != "true" && "${RERUN_AFTER_FDA}" != "true" ]]; then
  echo
  echo "This script will need your Mac account password for keychain operations."
  read -r -e -p "Enter your Mac ${ADMIN_USERNAME} account password: " -s ADMINISTRATOR_PASSWORD
  echo # Add newline after hidden input

  # Validate password by testing with dscl
  until _timeout 1 dscl /Local/Default -authonly "${USER}" "${ADMINISTRATOR_PASSWORD}" &>/dev/null; do
    echo "Invalid ${ADMIN_USERNAME} account password. Try again or ctrl-C to exit."
    read -r -e -p "Enter your Mac ${ADMIN_USERNAME} account password: " -s ADMINISTRATOR_PASSWORD
    echo # Add newline after hidden input
  done

  show_log "✅ Administrator password validated"
else
  log "🆗 Skipping password prompt (force mode or FDA re-run)"
fi

#
# SYSTEM CONFIGURATION
#

# TouchID and sudo configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-touchid-sudo.sh" --force
else
  "${SETUP_DIR}/scripts/setup-touchid-sudo.sh"
fi

# WiFi network configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-wifi-network.sh" --force
else
  "${SETUP_DIR}/scripts/setup-wifi-network.sh"
fi

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

# Hostname and volume configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-hostname-volume.sh" --force
else
  "${SETUP_DIR}/scripts/setup-hostname-volume.sh"
fi

# SSH access - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-ssh-access.sh" --force
else
  "${SETUP_DIR}/scripts/setup-ssh-access.sh"
fi

# Configure Remote Desktop (Screen Sharing and Remote Management)
section "Configuring Remote Desktop"

log "Remote Desktop requires GUI interaction to enable services, then automated permission setup"

# Run the user-guided setup script with proper verification
if [[ "${FORCE}" == "true" ]]; then
  log "Running Remote Desktop setup with --force flag"
  if "${SETUP_DIR}/scripts/setup-remote-desktop.sh" --force; then
    log "✅ Remote Desktop setup completed successfully with verification"
  else
    collect_error "Remote Desktop setup failed verification - Screen Sharing may not be working"
    log "Manual setup required: ${SETUP_DIR}/scripts/setup-remote-desktop.sh"
    log "Check System Settings > General > Sharing to enable Screen Sharing manually"
  fi
else
  log "Remote Desktop setup will automatically configure System Settings"
  if "${SETUP_DIR}/scripts/setup-remote-desktop.sh"; then
    log "✅ Remote Desktop setup completed successfully with verification"
  else
    collect_error "Remote Desktop setup failed verification - Screen Sharing may not be working"
    log "Manual setup required: ${SETUP_DIR}/scripts/setup-remote-desktop.sh"
    log "Check System Settings > General > Sharing to enable Screen Sharing manually"
  fi
fi

# After GUI setup, configure automated permissions for admin user
log "Configuring Remote Management privileges for admin user"
sudo -p "[Remote management] Enter password to configure admin privileges: " /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -users "${ADMIN_USERNAME}" \
  -access -on \
  -privs -all 2>/dev/null || {
  log "Note: Admin Remote Management privileges will be configured after services are enabled"
}
check_success "Admin Remote Management privileges (if services enabled)"

log "Note: Operator user privileges will be configured after account creation"

# Configure Apple ID
section "Apple ID Configuration"

# Check if Apple ID is already configured
APPLE_ID_CONFIGURED=false
if defaults read ~/Library/Preferences/MobileMeAccounts.plist 2>/dev/null >/dev/null; then
  # Try to get the configured Apple ID from AccountID field
  CONFIGURED_APPLE_ID=$(plutil -extract Accounts.0.AccountID raw ~/Library/Preferences/MobileMeAccounts.plist 2>/dev/null || echo "")
  if [[ -n "${CONFIGURED_APPLE_ID}" ]]; then
    show_log "✅ Apple ID already configured: ${CONFIGURED_APPLE_ID}"
    APPLE_ID_CONFIGURED=true
  else
    # Fallback - just check if the plist exists and has accounts
    ACCOUNT_COUNT=$(plutil -extract Accounts raw ~/Library/Preferences/MobileMeAccounts.plist 2>/dev/null | grep -c "AccountID" || echo "0")
    if [[ "${ACCOUNT_COUNT}" -gt 0 ]]; then
      show_log "✅ Apple ID already configured"
      APPLE_ID_CONFIGURED=true
    fi
  fi
fi

# Only prompt for Apple ID setup if not already configured
if [[ "${APPLE_ID_CONFIGURED}" != true ]]; then
  # Open Apple ID one-time password link if available
  APPLE_ID_URL_FILE="${SETUP_DIR}/config/apple_id_password.url"
  if [[ -f "${APPLE_ID_URL_FILE}" ]]; then
    log "Opening Apple ID one-time password link"
    open "${APPLE_ID_URL_FILE}"
    check_success "Opening Apple ID password link"

    # Ask user to confirm they've retrieved the password
    if [[ "${FORCE}" = false ]]; then
      read -rp "Have you retrieved your Apple ID password? (Y/n) " -n 1 -r
      echo
      # Default to Yes if Enter pressed (empty REPLY)
      if [[ -n "${REPLY}" ]] && [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        show_log "Please retrieve your Apple ID password before continuing"
        open "${APPLE_ID_URL_FILE}"
        read -p "Press any key to continue once you have your password... " -n 1 -r
        echo
      fi
    fi
  else
    log "No Apple ID one-time password link found - you'll need to retrieve your password manually"
  fi

  # Open System Settings to the Apple ID section
  if [[ "${FORCE}" = false ]]; then
    show_log "Opening System Settings to the Apple ID section"
    show_log "IMPORTANT: You will need to complete several steps:"
    show_log "1. Enter your Apple ID and password"
    show_log "2. You may be prompted to enter your Mac's user password"
    show_log "3. Approve any verification codes that are sent to your other devices"
    show_log "4. Select which services to enable (you can customize these)"
    show_log "5. Return to Terminal after completing all Apple ID setup dialogs"

    open "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"
    check_success "Opening Apple ID settings"

    # Give user time to add their Apple ID
    read -rp "Please configure your Apple ID in System Settings. Press any key when done... " -n 1 -r
    echo

    # Close System Settings now that user is done with Apple ID configuration
    show_log "Closing System Settings..."
    osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true
  fi
fi

# Configure iCloud and notification settings for admin user (always run)
section "Configuring iCloud and Notification Settings"

# Disable specific iCloud services for admin user (server doesn't need these)
log "Disabling unnecessary iCloud services for admin user"
defaults write com.apple.bird syncedDataclasses -dict \
  "Bookmarks" 0 \
  "Calendar" 0 \
  "Contacts" 0 \
  "Mail" 0 \
  "Messages" 0 \
  "Notes" 0 \
  "Reminders" 0
check_success "iCloud services configuration"

# Disable notifications for messaging apps
log "Disabling notifications for messaging apps"
defaults write com.apple.ncprefs apps -array-add '{
    "bundle-id" = "com.apple.FaceTime";
    "flags" = 0;
}'
defaults write com.apple.ncprefs apps -array-add '{
    "bundle-id" = "com.apple.MobileSMS";
    "flags" = 0;
}'
defaults write com.apple.ncprefs apps -array-add '{
    "bundle-id" = "com.apple.iChat";
    "flags" = 0;
}'
check_success "Notification settings configuration"

# Import credentials from external keychain
if ! import_external_keychain_credentials; then
  collect_error "External keychain credential import failed"
  exit 1
fi

# Create operator account if it doesn't exist
set_section "Setting Up Operator Account"
if dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
  log "Operator account already exists"
else
  log "Creating operator account"

  # Load keychain manifest
  manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
  # shellcheck source=/dev/null
  source "${manifest_file}"

  # Get credential securely from Keychain
  if operator_password=$(get_keychain_credential "${KEYCHAIN_OPERATOR_SERVICE}" "${KEYCHAIN_ACCOUNT}"); then
    log "Using password from Keychain (${ONEPASSWORD_OPERATOR_ITEM})"
  else
    log "❌ Failed to retrieve operator password from Keychain"
    exit 1
  fi

  # Create the operator account
  sudo -p "[Account setup] Enter password to create operator account: " sysadminctl -addUser "${OPERATOR_USERNAME}" -fullName "${OPERATOR_FULLNAME}" -password "${operator_password}" -hint "See 1Password ${ONEPASSWORD_OPERATOR_ITEM} for password" 2>/dev/null
  check_success "Operator account creation"

  # Comprehensive verification of operator account creation
  verify_operator_account_creation() {
    local verification_failed=false

    log "Performing comprehensive operator account verification..."

    # Test 1: Account exists in directory services
    if ! dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
      collect_error "Operator account does not exist in directory services"
      verification_failed=true
    else
      log "✓ Operator account exists in directory services"
    fi

    # Test 2: Password authentication works
    if ! dscl /Local/Default -authonly "${OPERATOR_USERNAME}" "${operator_password}" 2>/dev/null; then
      collect_error "Operator account password authentication failed"
      verification_failed=true
    else
      log "✓ Operator account password authentication successful"
    fi

    # Test 3: Home directory exists and is accessible
    local home_dir="/Users/${OPERATOR_USERNAME}"
    if [[ ! -d "${home_dir}" ]]; then
      collect_error "Operator home directory does not exist: ${home_dir}"
      verification_failed=true
    else
      # Check ownership using stat
      local owner_info
      owner_info=$(stat -f "%Su:%Sg" "${home_dir}" 2>/dev/null || echo "unknown:unknown")
      if [[ "${owner_info}" == "${OPERATOR_USERNAME}:staff" ]]; then
        log "✓ Operator home directory exists with correct ownership"
      else
        collect_warning "Operator home directory ownership may be incorrect: ${owner_info}"
      fi
    fi

    # Overall status
    if [[ "${verification_failed}" == "true" ]]; then
      collect_error "Operator account creation verification FAILED"
      return 1
    else
      show_log "✅ Operator account creation verification PASSED"
      return 0
    fi
  }

  # Run the verification
  if ! verify_operator_account_creation; then
    unset operator_password
    exit 1
  fi

  # Store reference to 1Password (don't store actual password)
  echo "Operator account password is stored in 1Password: op://${ONEPASSWORD_VAULT}/${ONEPASSWORD_OPERATOR_ITEM}/password" >"/Users/${ADMIN_USERNAME}/Documents/operator_password_reference.txt"
  chmod 600 "/Users/${ADMIN_USERNAME}/Documents/operator_password_reference.txt"

  show_log "Operator account created successfully"

  # Note: Operator keychain population no longer needed
  # SMB credentials are now embedded directly in mount scripts during plex-setup.sh
  # This eliminates the need to unlock operator keychain before first login
  log "✅ Operator keychain operations skipped - credentials embedded in service scripts"

  # Clear password from memory since we don't need it for keychain operations
  unset operator_password

  # Skip setup screens for operator account (more aggressive approach)
  log "Configuring operator account to skip setup screens"
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant DidSeeCloudSetup -bool true
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant SkipCloudSetup -bool true
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant DidSeePrivacy -bool true
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant GestureMovieSeen none
  PRODUCT_VERSION=$(sw_vers -productVersion)
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant LastSeenCloudProductVersion "${PRODUCT_VERSION}"
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.screensaver showClock -bool false

  # Screen Time and Apple Intelligence
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.ScreenTimeAgent DidCompleteSetup -bool true
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.intelligenceplatform.ui SetupHasBeenDisplayed -bool true

  # Accessibility and Data & Privacy
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.universalaccess didSeeAccessibilitySetup -bool true
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant DidSeeDataAndPrivacy -bool true

  # TouchID setup bypass (this might help with the password confusion)
  sudo -u "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant DidSeeTouchID -bool true
  check_success "Operator setup screen suppression"

  # Set up operator SSH keys if available
  if [[ -d "${SSH_KEY_SOURCE}" ]] && [[ -f "${SSH_KEY_SOURCE}/operator_authorized_keys" ]]; then
    OPERATOR_SSH_DIR="/Users/${OPERATOR_USERNAME}/.ssh"
    log "Setting up SSH keys for operator account"

    sudo -p "[SSH setup] Enter password to configure operator SSH keys: " mkdir -p "${OPERATOR_SSH_DIR}"
    sudo cp "${SSH_KEY_SOURCE}/operator_authorized_keys" "${OPERATOR_SSH_DIR}/authorized_keys"
    sudo chmod 700 "${OPERATOR_SSH_DIR}"
    sudo chmod 600 "${OPERATOR_SSH_DIR}/authorized_keys"
    sudo chown -R "${OPERATOR_USERNAME}" "${OPERATOR_SSH_DIR}"

    check_success "Operator SSH key setup"

    # Add operator to SSH access group
    log "Adding operator to SSH access group"
    sudo -p "[SSH setup] Enter password to add operator to SSH access group: " dseditgroup -o edit -a "${OPERATOR_USERNAME}" -t user com.apple.access_ssh
    check_success "Operator SSH group membership"
  fi

  # Configure Remote Management for operator user (now that account exists)
  log "Configuring Remote Management privileges for operator user"
  sudo -p "[Remote management] Enter password to configure operator privileges: " /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -configure -users "${OPERATOR_USERNAME}" \
    -access -on \
    -privs -all

  check_success "Operator Remote Management privileges"
  show_log "✅ Remote Management configured for operator user"
fi

# Fast User Switching
section "Enabling Fast User Switching"
log "Configuring Fast User Switching for multi-user access"
sudo -p "[System setup] Enter password to enable multiple user sessions: " defaults write /Library/Preferences/.GlobalPreferences MultipleSessionEnabled -bool true
check_success "Fast User Switching configuration"

# Fast User Switching menu bar style and visibility
defaults write .GlobalPreferences userMenuExtraStyle -int 1                                                                                                     # username
sudo -p "[User setup] Enter password to configure operator menu style: " -iu "${OPERATOR_USERNAME}" defaults write .GlobalPreferences userMenuExtraStyle -int 1 # username
defaults -currentHost write com.apple.controlcenter UserSwitcher -int 2                                                                                         # menubar
sudo -iu "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.controlcenter UserSwitcher -int 2                                                         # menubar

# Configure automatic login for operator account (whether new or existing)
section "Automatic login for operator account"
log "Configuring automatic login for operator account"
# Load keychain manifest
manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
# shellcheck source=/dev/null
source "${manifest_file}"

# Get credential securely from admin Keychain for auto-login
log "Retrieving operator password from admin keychain for automatic login setup"
if operator_password=$(get_keychain_credential "${KEYCHAIN_OPERATOR_SERVICE}" "${KEYCHAIN_ACCOUNT}"); then
  # Create the encoded password file that macOS uses for auto-login
  encoded_password=$(echo "${operator_password}" | openssl enc -base64)
  echo "${encoded_password}" | sudo -p "[Auto-login] Enter password to configure automatic login: " tee /etc/kcpassword >/dev/null
  sudo chmod 600 /etc/kcpassword
  check_success "Create auto-login password file"

  # Set the auto-login user
  sudo -p "[Auto-login] Enter password to set auto-login user: " defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "${OPERATOR_USERNAME}"
  check_success "Set auto-login user"

  # Clear passwords from memory immediately
  unset operator_password encoded_password

  # Comprehensive verification of auto-login configuration
  verify_autologin_configuration() {
    local verification_failed=false

    log "Performing comprehensive auto-login verification..."

    # Test 1: Auto-login user is correctly configured
    local auto_login_user
    auto_login_user=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo "")
    if [[ "${auto_login_user}" != "${OPERATOR_USERNAME}" ]]; then
      collect_error "Auto-login is not configured for operator account (current: ${auto_login_user:-none})"
      verification_failed=true
    else
      log "✓ Auto-login is configured for operator account"
    fi

    # Test 2: Auto-login password file exists
    if [[ ! -f "/etc/kcpassword" ]]; then
      collect_error "Auto-login password file missing (/etc/kcpassword)"
      verification_failed=true
    else
      local kcpassword_perms
      kcpassword_perms=$(stat -f "%Mp%Lp" /etc/kcpassword 2>/dev/null || echo "unknown")
      if [[ "${kcpassword_perms}" == "600" || "${kcpassword_perms}" == "0600" ]]; then
        log "✓ Auto-login password file exists with correct permissions"
      else
        collect_error "Auto-login password file has incorrect permissions: ${kcpassword_perms} (should be 600)"
        verification_failed=true
      fi
    fi

    # Test 3: FileVault compatibility check (if not already done)
    local filevault_status
    filevault_status=$(fdesetup status 2>/dev/null || echo "unknown")
    if [[ "${filevault_status}" == *"FileVault is On"* ]]; then
      collect_error "FileVault is enabled - this will prevent auto-login from working"
      verification_failed=true
    elif [[ "${filevault_status}" == *"FileVault is Off"* ]]; then
      log "✓ FileVault is disabled - auto-login compatibility confirmed"
    else
      collect_warning "FileVault status unclear for auto-login: ${filevault_status}"
    fi

    # Overall status
    if [[ "${verification_failed}" == "true" ]]; then
      collect_error "Auto-login configuration verification FAILED - operator may not auto-login"
      return 1
    else
      show_log "✅ Auto-login configuration verification PASSED"
      return 0
    fi
  }

  # Run auto-login verification
  if verify_autologin_configuration; then
    show_log "✅ Automatic login configured and verified for ${OPERATOR_USERNAME}"
  else
    collect_error "Auto-login configuration failed verification"
  fi
else
  collect_warning "Failed to retrieve operator password from admin keychain - skipping automatic login setup"
  log "⚠️ Operator will need to log in manually on first boot"
fi

# Add operator to sudoers
section "Configuring sudo access for operator"
log "Adding operator account to sudoers"

# Add operator to admin group for sudo access
sudo -p "[Account setup] Enter password to add operator to admin group: " dseditgroup -o edit -a "${OPERATOR_USERNAME}" -t user admin
check_success "Operator admin group membership"

# Verify sudo access works for operator
log "Verifying sudo access for operator"
if sudo -p "[Account setup] Enter password to verify operator sudo access: " -u "${OPERATOR_USERNAME}" sudo -n true 2>/dev/null; then
  show_log "✅ Operator sudo access verified (passwordless test)"
else
  # This is expected - they'll need to enter password for sudo
  show_log "✅ Operator has sudo access (will require password)"
fi

# Fix scroll setting
section "Fix scroll setting"
log "Fixing Apple's default scroll setting"
defaults write -g com.apple.swipescrolldirection -bool false
sudo -p "[User setup] Enter password to configure operator scroll direction: " -iu "${OPERATOR_USERNAME}" defaults write -g com.apple.swipescrolldirection -bool false
check_success "Fix scroll setting"

# Power management configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-power-management.sh" --force
else
  "${SETUP_DIR}/scripts/setup-power-management.sh"
fi

# Configure screen saver password requirement
section "Configuring screen saver password requirement"
defaults -currentHost write com.apple.screensaver askForPassword -int 1
defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0
sudo -p "[Security setup] Enter password to configure operator screen saver security: " -u "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.screensaver askForPassword -int 1
sudo -u "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0
log "Enabled immediate password requirement after screen saver"

# Run software updates if not skipped
if [[ "${SKIP_UPDATE}" = false ]]; then
  section "Running Software Updates"
  show_log "Checking for software updates (this may take a while)"

  # Check for updates
  UPDATE_CHECK=$(softwareupdate -l)
  if echo "${UPDATE_CHECK}" | grep -q "No new software available"; then
    log "System is up to date"
  else
    log "Installing software updates in background mode"
    sudo -p "[System update] Enter password to install software updates: " softwareupdate -i -a --background
    check_success "Initiating background software update"
  fi
else
  log "Skipping software updates as requested"
fi

# Firewall configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-firewall.sh" --force
else
  "${SETUP_DIR}/scripts/setup-firewall.sh"
fi

# Configure security settings
section "Configuring Security Settings"

# Disable automatic app downloads
defaults write com.apple.SoftwareUpdate AutomaticDownload -int 0
log "Disabled automatic app downloads"

#
# HOMEBREW & PACKAGE INSTALLATION
#

# Install Xcode Command Line Tools using dedicated script
set_section "Installing Xcode Command Line Tools"

# Use the dedicated CLT installation script with enhanced monitoring
clt_script="${SETUP_DIR}/scripts/setup-command-line-tools.sh"

if [[ -f "${clt_script}" ]]; then
  log "Using enhanced Command Line Tools installation script..."

  # Prepare CLT installation arguments
  clt_args=()
  if [[ "${FORCE}" = true ]]; then
    clt_args+=(--force)
  fi

  # Run the dedicated CLT installation script
  if "${clt_script}" "${clt_args[@]}"; then
    log "✅ Command Line Tools installation completed successfully"
  else
    collect_error "Command Line Tools installation failed"
    exit 1
  fi
else
  collect_error "CLT installation script not found: ${clt_script}"
  log "Please ensure setup-command-line-tools.sh is present in the scripts directory"
  exit 1
fi

# Install Homebrew
if [[ "${SKIP_HOMEBREW}" = false ]]; then
  section "Installing Homebrew"

  # Check if Homebrew is already installed
  if command -v brew &>/dev/null; then
    BREW_VERSION=$(brew --version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "unknown")
    log "Homebrew is already installed (version ${BREW_VERSION})"

    # Update Homebrew if already installed
    log "Updating Homebrew"
    brew update
    check_success "Homebrew update"
    log "Updating installed packages"
    brew upgrade
    check_success "Homebrew package upgrade"
  else
    show_log "Installing Homebrew using official installation script"

    # Use the official Homebrew installation script
    HOMEBREW_INSTALLER=$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
    NONINTERACTIVE=1 /bin/bash -c "${HOMEBREW_INSTALLER}"
    check_success "Homebrew installation"

    # Follow Homebrew's suggested post-installation steps
    log "Running Homebrew's suggested post-installation steps"

    # Add to .zprofile (Homebrew's recommended approach)
    echo >>"/Users/${ADMIN_USERNAME}/.zprofile"
    echo "eval \"\$(${HOMEBREW_PREFIX}/bin/brew shellenv)\"" >>"/Users/${ADMIN_USERNAME}/.zprofile"
    log "Added Homebrew to .zprofile"

    # Apply to current session
    BREW_SHELLENV=$("${HOMEBREW_PREFIX}/bin/brew" shellenv)
    eval "${BREW_SHELLENV}"
    log "Applied Homebrew environment to current session"

    # Add to other shell configuration files for compatibility
    for SHELL_PROFILE in ~/.bash_profile ~/.profile; do
      if [[ -f "${SHELL_PROFILE}" ]]; then
        # Only add if not already present
        if ! grep -q "HOMEBREW_PREFIX\|brew shellenv" "${SHELL_PROFILE}"; then
          log "Adding Homebrew to ${SHELL_PROFILE}"
          echo -e '\n# Homebrew' >>"${SHELL_PROFILE}"
          echo "eval \"\$(${HOMEBREW_PREFIX}/bin/brew shellenv)\"" >>"${SHELL_PROFILE}"
        fi
      fi
    done

    show_log "Homebrew installation completed"

    # Verify installation with brew help
    if brew help >/dev/null 2>&1; then
      show_log "✅ Homebrew verification successful"
    else
      collect_error "Homebrew verification failed - brew help returned an error"
      exit 1
    fi
  fi
fi

# Add concurrent download configuration
section "Configuring Homebrew for Optimal Performance"
export HOMEBREW_DOWNLOAD_CONCURRENCY=auto
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo "2x")"
log "Enabled concurrent downloads (auto mode - using ${CORES} CPU cores for optimal parallelism)"

# Install packages
if [[ "${SKIP_PACKAGES}" = false ]]; then
  section "Installing Packages"

  # Function to install formulae if not already installed
  install_formula() {
    if ! brew list "$1" &>/dev/null; then
      log "Installing formula: $1"
      if brew install "$1"; then
        log "✅ Formula installation: $1"
      else
        collect_error "Formula installation failed: $1"
        # Continue instead of exiting
      fi
    else
      log "Formula already installed: $1"
    fi
  }

  # Function to install casks if not already installed
  install_cask() {
    if ! brew list --cask "$1" &>/dev/null; then
      log "Installing cask: $1"

      # Capture /Applications before installation
      local before_apps
      before_apps=$(find /Applications -maxdepth 1 -type d -name "*.app" 2>/dev/null | sort)

      if brew install --cask "$1"; then
        log "✅ Cask installation: $1"

        # Capture /Applications after installation
        local after_apps
        after_apps=$(find /Applications -maxdepth 1 -type d -name "*.app" 2>/dev/null | sort)

        # Find newly installed apps and remove quarantine attributes
        local new_apps
        new_apps=$(comm -13 <(echo "${before_apps}") <(echo "${after_apps}"))

        if [[ -n "${new_apps}" ]]; then
          while IFS= read -r app_path; do
            if [[ -n "${app_path}" ]]; then
              log "Removing quarantine attribute from: $(basename "${app_path}")"
              xattr -d com.apple.quarantine "${app_path}" 2>/dev/null || true
            fi
          done <<<"${new_apps}"
        fi
      else
        collect_error "Cask installation failed: $1"
        # Continue instead of exiting
      fi
    else
      log "Cask already installed: $1"
    fi
  }

  # Install formulae from list
  if [[ -f "${FORMULAE_FILE}" ]]; then
    show_log "Installing formulae from ${FORMULAE_FILE}"
    formulae=()
    if [[ -f "${FORMULAE_FILE}" ]]; then
      while IFS= read -r line; do
        if [[ -n "${line}" && ! "${line}" =~ ^# ]]; then
          formulae+=("${line}")
        fi
      done <"${FORMULAE_FILE}"
    fi
    for formula in "${formulae[@]}"; do
      install_formula "${formula}"
    done
  else
    log "Formulae list not found, skipping formula installations"
  fi

  # Install casks from list
  if [[ -f "${CASKS_FILE}" ]]; then
    show_log "Installing casks from ${CASKS_FILE}"
    casks=()
    if [[ -f "${CASKS_FILE}" ]]; then
      while IFS= read -r line; do
        if [[ -n "${line}" && ! "${line}" =~ ^# ]]; then
          casks+=("${line}")
        fi
      done <"${CASKS_FILE}"
    fi
    for cask in "${casks[@]}"; do
      install_cask "${cask}"
    done
  else
    log "Casks list not found, skipping cask installations"
  fi

  # Cleanup after installation
  log "Cleaning up Homebrew files"
  brew cleanup
  check_success "Homebrew cleanup"

  # Run brew doctor and save output
  log "Running brew doctor diagnostic"
  BREW_DOCTOR_OUTPUT="${LOG_DIR}/brew-doctor-$(date +%Y%m%d-%H%M%S).log"
  brew doctor >"${BREW_DOCTOR_OUTPUT}" 2>&1 || true
  log "Brew doctor output saved to: ${BREW_DOCTOR_OUTPUT}"
  check_success "Brew doctor diagnostic"

fi

#
# RELOAD PROFILE FOR CURRENT SESSION
#
section "Reload Profile"
# shellcheck source=/dev/null
source ~/.zprofile
check_success "Reload profile"

#
# CLEAN UP DOCK
#
section "Cleaning up Administrator Dock"
log "Cleaning up Administrator Dock"
if command -v dockutil &>/dev/null; then
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
else
  log "Could not locate dockutil"
fi

# Note: Operator first-login setup is now handled automatically via LaunchAgent
# See the "Configuring operator account files" section above

#
# CHANGE DEFAULT SHELL TO HOMEBREW BASH
#
section "Changing Default Shell to Homebrew Bash"

# Get the Homebrew bash path
HOMEBREW_BASH="$(brew --prefix)/bin/bash"

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

#
# LOG ROTATION SETUP
#
section "Configuring Log Rotation"

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
  brew services stop logrotate &>/dev/null || true
  if brew services start logrotate; then
    check_success "Admin logrotate service start"
    log "✅ Admin logrotate service started - admin logs will be rotated automatically"
  else
    log "⚠️  Failed to start admin logrotate service - admin logs will not be rotated"
  fi
else
  log "No logrotate configuration found - skipping log rotation setup"
fi

#
# APPLICATION SETUP PREPARATION
#

# Create application setup directory
set_section "Preparing Application Setup"
APP_SETUP_DIR="/Users/${ADMIN_USERNAME}/app-setup"

if [[ ! -d "${APP_SETUP_DIR}" ]]; then
  log "Creating application setup directory"
  mkdir -p "${APP_SETUP_DIR}"
  check_success "App setup directory creation"
fi

# Copy application setup directory preserving organized structure
if [[ -d "${SETUP_DIR}/app-setup" ]]; then
  log "Copying application setup directory with organized structure from ${SETUP_DIR}/app-setup"

  # Copy the entire app-setup directory structure
  cp -R "${SETUP_DIR}/app-setup/"* "${APP_SETUP_DIR}/" 2>/dev/null

  # Set proper permissions
  chmod +x "${APP_SETUP_DIR}/"*.sh 2>/dev/null
  chmod 600 "${APP_SETUP_DIR}/config/"*.conf 2>/dev/null || true
  chmod 755 "${APP_SETUP_DIR}/templates/"*.sh 2>/dev/null || true

  check_success "Application directory copy with organized structure"
else
  log "No application setup directory found in ${SETUP_DIR}/app-setup"
fi

# Script templates are now copied above as part of the organized directory structure

# Copy config.conf for application setup scripts
if [[ -f "${CONFIG_FILE}" ]]; then
  log "Copying config.conf to app-setup config directory"
  mkdir -p "${APP_SETUP_DIR}/config"
  cp "${CONFIG_FILE}" "${APP_SETUP_DIR}/config/config.conf"
  check_success "Config file copy"
else
  log "No config.conf found - application setup scripts will use defaults"
fi

# Copy Dropbox configuration files if available (already copied above from app-setup/config)
# These files are now handled in the "Copy application config files" section above
log "Dropbox and rclone config files are copied from app-setup/config/ directory above"

# Setup operator account files
section "Configuring operator account files"
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
OPERATOR_CONFIG_DIR="${OPERATOR_HOME}/.config/operator"
OPERATOR_BIN_DIR="${OPERATOR_HOME}/.local/bin"

if [[ -f "${CONFIG_FILE}" ]]; then
  log "Setting up operator configuration directory"
  sudo -p "[Operator setup] Enter password to create operator config directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_CONFIG_DIR}"
  sudo -p "[Operator setup] Enter password to copy config.conf for operator: " cp "${CONFIG_FILE}" "${OPERATOR_CONFIG_DIR}/config.conf"
  sudo -p "[Operator setup] Enter password to set config ownership: " chown "${OPERATOR_USERNAME}:staff" "${OPERATOR_CONFIG_DIR}/config.conf"
  check_success "Operator config.conf copy"
fi

if [[ -f "${SETUP_DIR}/scripts/operator-first-login.sh" ]]; then
  log "Setting up operator first-login script"
  sudo -p "[Operator setup] Enter password to create operator bin directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_BIN_DIR}"
  sudo -p "[Operator setup] Enter password to copy first-login script: " cp "${SETUP_DIR}/scripts/operator-first-login.sh" "${OPERATOR_BIN_DIR}/"
  sudo -p "[Operator setup] Enter password to set script ownership and permissions: " chown "${OPERATOR_USERNAME}:staff" "${OPERATOR_BIN_DIR}/operator-first-login.sh"
  sudo -p "[Operator setup] Enter password to make first-login script executable: " chmod 755 "${OPERATOR_BIN_DIR}/operator-first-login.sh"
  check_success "Operator first-login script setup"

  # Add ~/.local/bin to operator's PATH in bash configuration
  OPERATOR_BASHRC="${OPERATOR_HOME}/.bashrc"
  if ! sudo -u "${OPERATOR_USERNAME}" test -f "${OPERATOR_BASHRC}" || ! sudo -u "${OPERATOR_USERNAME}" grep -q '/.local/bin' "${OPERATOR_BASHRC}"; then
    log "Adding ~/.local/bin to operator's PATH"
    sudo -p "[Operator setup] Enter password to configure operator PATH: " tee -a "${OPERATOR_BASHRC}" >/dev/null <<EOF

# Add user local bin to PATH
export PATH="\$HOME/.local/bin:\$PATH"
EOF
    sudo -p "[Operator setup] Enter password to set bashrc ownership: " chown "${OPERATOR_USERNAME}:staff" "${OPERATOR_BASHRC}"
    check_success "Operator PATH configuration"
  fi

  # Create LaunchAgent for one-time execution on operator login
  log "Setting up operator first-login LaunchAgent"
  OPERATOR_AGENTS_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
  OPERATOR_PLIST_NAME="com.${HOSTNAME_LOWER}.operator-first-login"
  OPERATOR_PLIST="${OPERATOR_AGENTS_DIR}/${OPERATOR_PLIST_NAME}.plist"

  sudo -p "[Operator setup] Enter password to create operator LaunchAgent directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_AGENTS_DIR}"

  sudo -p "[Operator setup] Enter password to create operator first-login LaunchAgent: " -u "${OPERATOR_USERNAME}" tee "${OPERATOR_PLIST}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${OPERATOR_PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OPERATOR_BIN_DIR}/operator-first-login.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${OPERATOR_HOME}/.local/state/${OPERATOR_PLIST_NAME}.log</string>
    <key>StandardErrorPath</key>
    <string>${OPERATOR_HOME}/.local/state/${OPERATOR_PLIST_NAME}.log</string>
</dict>
</plist>
EOF

  sudo -p "[Operator setup] Enter password to set LaunchAgent permissions: " -u "${OPERATOR_USERNAME}" chmod 644 "${OPERATOR_PLIST}"
  check_success "Operator first-login LaunchAgent setup"
else
  log "No operator-first-login.sh found in ${SETUP_DIR}/scripts/"
fi

#
# BASH CONFIGURATION SETUP - delegated to module
#

# Bash configuration setup - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-bash-configuration.sh" --force
else
  "${SETUP_DIR}/scripts/setup-bash-configuration.sh"
fi

#
# TIME MACHINE CONFIGURATION
#

# Time Machine configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-timemachine.sh" --force
else
  "${SETUP_DIR}/scripts/setup-timemachine.sh"
fi

# Apply menu bar changes
if [[ "${NEED_SYSTEMUI_RESTART}" = true ]]; then
  log "Restarting SystemUIServer to apply menu bar changes"
  killall SystemUIServer
  check_success "SystemUIServer restart for menu bar updates"
fi
if [[ "${NEED_CONTROLCENTER_RESTART}" = true ]]; then
  log "Restarting Control Center to apply menu bar changes"
  killall ControlCenter
  check_success "Control Center restart for menu bar updates"
fi

# Setup completed successfully
section "Setup Complete"
show_log "Server setup has been completed successfully"
show_log "You can now set up individual applications with scripts in: ${APP_SETUP_DIR}"
show_log ""
show_log "Next steps:"
show_log "1. Set up applications: cd ${APP_SETUP_DIR} && ./plex-setup.sh"
show_log "   (The script will prompt for your Mac account password)"
show_log "2. Test SSH access from your dev machine:"
show_log "   ssh ${ADMIN_USERNAME}@${HOSTNAME_LOWER}.local"
show_log "   ssh operator@${HOSTNAME_LOWER}.local"
show_log ""
show_log "3. After completing app setup, reboot to enable operator auto-login:"
show_log "   - Rebooting will automatically log in as '${OPERATOR_USERNAME}'"
show_log "   - Dock cleanup and operator customization will happen automatically"
show_log "   - Configure any additional operator-specific settings"
show_log "   - Test that all applications are accessible as the operator"
show_log ""
show_log "4. The next Terminal session, window, or tab will use the installed"
show_log "   Bash shell and custom settings for both Administrator and Operator accounts."

# Clean up temporary sudo timeout configuration
log "Removing temporary sudo timeout configuration"
sudo rm -f /etc/sudoers.d/10_setup_timeout

# Clean up external keychain from setup directory (only after successful completion)
if [[ -n "${EXTERNAL_KEYCHAIN:-}" ]]; then
  setup_keychain_file="${SETUP_DIR}/config/${EXTERNAL_KEYCHAIN}-db"
  if [[ -f "${setup_keychain_file}" ]]; then
    log "Cleaning up external keychain from setup directory"
    rm -f "${setup_keychain_file}"
    log "✅ Setup keychain file cleaned up"
  fi
fi

# Clean up administrator password from memory
if [[ -n "${ADMINISTRATOR_PASSWORD:-}" ]]; then
  unset ADMINISTRATOR_PASSWORD
  log "✅ Administrator password cleared from memory"
fi

# Show collected errors and warnings
show_collected_issues

exit 0
