#!/usr/bin/env bash
#
# setup-ssh-access.sh - SSH access configuration module
#
# This script configures SSH access including service enablement and key setup.
# It handles Full Disk Access requirements for SSH enablement and copies
# SSH keys for both admin and operator accounts.
#
# Usage: ./setup-ssh-access.sh [--force]
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
ADMIN_USERNAME=$(whoami)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
SSH_KEY_SOURCE="${SETUP_DIR}/ssh_keys"

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

# SSH ACCESS CONFIGURATION
#

set_section "Configuring SSH Access"

# 1. Check if remote login is already enabled
if sudo -p "[SSH check] Enter password to check SSH status: " systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
  log "SSH is already enabled"
else
  # 2. Try to enable it directly first
  log "Attempting to enable SSH..."
  if sudo -p "[SSH setup] Enter password to enable SSH access: " systemsetup -setremotelogin on; then
    # 3.a Success case - it worked directly
    show_log "✅ SSH has been enabled successfully"
  else
    # 3.b Failure case - need FDA
    # Create a marker file to detect re-run
    touch "/tmp/${HOSTNAME_LOWER}_fda_requested"
    show_log "We need to grant Full Disk Access permissions to Terminal to enable SSH."
    show_log "1. We'll open System Settings to the Full Disk Access section"
    show_log "2. We'll open Finder showing Terminal.app"
    show_log "3. You'll need to drag Terminal from Finder into the FDA list"
    show_log "4. IMPORTANT: After adding Terminal, you must CLOSE this Terminal window"
    show_log "5. Then open a NEW Terminal window and run this script again"

    # Open Finder to show Terminal app
    log "Opening Finder window to locate Terminal.app..."
    osascript <<EOF
tell application "Finder"
  activate
  open folder "Applications:Utilities:" of startup disk
  select file "Terminal.app" of folder "Utilities" of folder "Applications" of startup disk
end tell
EOF

    # Open FDA preferences
    log "Opening System Settings to the Full Disk Access section..."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    show_log "After granting Full Disk Access to Terminal, close this window and run the script again."
    exit 0
  fi
fi

# Copy SSH keys if available
if [[ -d "${SSH_KEY_SOURCE}" ]]; then
  log "Found SSH keys at ${SSH_KEY_SOURCE}"

  # Set up admin SSH keys
  ADMIN_SSH_DIR="/Users/${ADMIN_USERNAME}/.ssh"
  if [[ ! -d "${ADMIN_SSH_DIR}" ]]; then
    log "Creating SSH directory for admin user"
    mkdir -p "${ADMIN_SSH_DIR}"
    chmod 700 "${ADMIN_SSH_DIR}"
  fi

  if [[ -f "${SSH_KEY_SOURCE}/authorized_keys" ]]; then
    log "Copying authorized_keys for admin user"
    cp "${SSH_KEY_SOURCE}/authorized_keys" "${ADMIN_SSH_DIR}/"
    chmod 600 "${ADMIN_SSH_DIR}/authorized_keys"
    check_success "Admin authorized_keys setup"
  fi

  # Copy SSH key pair for outbound connections
  if [[ -f "${SSH_KEY_SOURCE}/id_ed25519.pub" ]]; then
    log "Copying SSH public key for admin user"
    cp "${SSH_KEY_SOURCE}/id_ed25519.pub" "${ADMIN_SSH_DIR}/"
    chmod 644 "${ADMIN_SSH_DIR}/id_ed25519.pub"
    check_success "Admin SSH public key setup"
  fi

  if [[ -f "${SSH_KEY_SOURCE}/id_ed25519" ]]; then
    log "Copying SSH private key for admin user"
    cp "${SSH_KEY_SOURCE}/id_ed25519" "${ADMIN_SSH_DIR}/"
    chmod 600 "${ADMIN_SSH_DIR}/id_ed25519"
    check_success "Admin SSH private key setup"
  fi

  # Set up operator SSH keys if available and operator account exists
  if [[ -f "${SSH_KEY_SOURCE}/operator_authorized_keys" ]] && [[ -n "${OPERATOR_USERNAME:-}" ]]; then
    if dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
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
    else
      log "Operator account not found - skipping operator SSH key setup"
    fi
  fi
else
  log "No SSH keys found at ${SSH_KEY_SOURCE} - manual key setup will be required"
fi

show_log "✅ SSH access module completed successfully"

exit 0