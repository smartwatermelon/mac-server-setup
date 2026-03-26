#!/usr/bin/env bash
#
# msmtp-setup.sh - Shared email facility setup for Mac Mini server
#
# Sets up msmtp as a lightweight SMTP relay for Gmail, usable by any
# monitoring or alerting script on the server. The Gmail App Password is
# embedded directly in the msmtp config file (mode 600, owned by operator),
# following the same credential pattern used by other services in this repo.
#
# Usage: ./msmtp-setup.sh [--force] [--password PASSWORD]
#   --force:    Skip all confirmation prompts
#   --password: Provide Gmail App Password non-interactively
#
# Prerequisites:
#   - Homebrew installed
#   - config/config.conf with MONITORING_EMAIL set
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-03-25

set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate working directory
if [[ "${PWD}" != "${SCRIPT_DIR}" ]] || [[ "$(basename "${SCRIPT_DIR}")" != "app-setup" ]]; then
  echo "Error: This script must be run from the app-setup directory"
  echo ""
  echo "Current directory: ${PWD}"
  echo "Script directory: ${SCRIPT_DIR}"
  echo ""
  echo "Please change to the app-setup directory and try again:"
  echo "  cd \"${SCRIPT_DIR}\" && ./msmtp-setup.sh"
  echo ""
  exit 1
fi

# Load server configuration
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Derive configuration variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"

# Validate MONITORING_EMAIL — prompt if not configured
if [[ -z "${MONITORING_EMAIL:-}" ]] || [[ "${MONITORING_EMAIL}" == "your-email@example.com" ]]; then
  echo ""
  echo "MONITORING_EMAIL is not configured in ${CONFIG_FILE}"
  read -r -p "Enter the email address for monitoring alerts: " MONITORING_EMAIL
  echo ""

  if [[ -z "${MONITORING_EMAIL}" ]]; then
    echo "Error: No email address provided."
    exit 1
  fi

  # Update config.conf with the provided email (escape sed special chars in value)
  escaped_email=$(printf '%s\n' "${MONITORING_EMAIL}" | sed -e 's/[&\|/]/\\&/g')
  sed -i '' "s|^MONITORING_EMAIL=.*|MONITORING_EMAIL=\"${escaped_email}\"|" "${CONFIG_FILE}"
  echo "Updated MONITORING_EMAIL in ${CONFIG_FILE}"
fi

# Logging
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-msmtp-setup.log"
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

show_log() {
  echo "$*" | tee -a "${LOG_FILE}"
}

section() {
  echo ""
  show_log "=================================================================================="
  show_log "$1"
  show_log "=================================================================================="
  echo ""
}

# Error and warning collection
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
CURRENT_SCRIPT_SECTION=""

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

collect_error() {
  local message="$1"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  log "Error: ${clean_message}"
  COLLECTED_ERRORS+=("[${context}] ${clean_message}")
}

collect_warning() {
  local message="$1"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  log "Warning: ${clean_message}"
  COLLECTED_WARNINGS+=("[${context}] ${clean_message}")
}

show_collected_issues() {
  local error_count=${#COLLECTED_ERRORS[@]}
  local warning_count=${#COLLECTED_WARNINGS[@]}

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    log "msmtp setup completed successfully with no errors or warnings!"
    return
  fi

  log ""
  log "====== MSMTP SETUP SUMMARY ======"
  log "Setup completed with ${error_count} errors and ${warning_count} warnings:"
  log ""

  if [[ ${error_count} -gt 0 ]]; then
    log "ERRORS:"
    for error in "${COLLECTED_ERRORS[@]}"; do
      log "  ${error}"
    done
  fi

  if [[ ${warning_count} -gt 0 ]]; then
    log "WARNINGS:"
    for warning in "${COLLECTED_WARNINGS[@]}"; do
      log "  ${warning}"
    done
  fi
}

trap 'show_collected_issues' EXIT

# Parse command line arguments
FORCE=false
APP_PASSWORD_ARG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --password)
      APP_PASSWORD_ARG="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--force] [--password PASSWORD]"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Section 1: Install msmtp and jq via Homebrew
# ---------------------------------------------------------------------------

set_section "Install Dependencies"

if command -v msmtp &>/dev/null; then
  log "msmtp already installed: $(msmtp --version | head -1)"
else
  log "Installing msmtp via Homebrew..."
  if brew install msmtp; then
    log "msmtp installed: $(msmtp --version | head -1)"
  else
    collect_error "Failed to install msmtp via Homebrew"
    exit 1
  fi
fi

if command -v jq &>/dev/null; then
  log "jq already installed: $(jq --version)"
else
  log "Installing jq via Homebrew..."
  if brew install jq; then
    log "jq installed: $(jq --version)"
  else
    collect_error "Failed to install jq via Homebrew"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Section 2: Obtain Gmail App Password
# ---------------------------------------------------------------------------

set_section "Gmail App Password"

MSMTP_CONFIG_DIR="${OPERATOR_HOME}/.config/msmtp"
MSMTP_CONFIG="${MSMTP_CONFIG_DIR}/config"
MSMTP_LOG="${OPERATOR_HOME}/.local/state/msmtp.log"

# Check if msmtp config already exists with an embedded password
if [[ -f "${MSMTP_CONFIG}" ]] && grep -q '^password ' "${MSMTP_CONFIG}" 2>/dev/null; then
  log "msmtp config already exists with embedded password at ${MSMTP_CONFIG}"
  if [[ "${FORCE}" != "true" ]]; then
    log "Use --force to overwrite existing configuration"
    APP_PASSWORD="__EXISTING__"
  fi
fi

if [[ -z "${APP_PASSWORD:-}" ]]; then
  if [[ -n "${APP_PASSWORD_ARG}" ]]; then
    APP_PASSWORD="${APP_PASSWORD_ARG}"
  else
    echo ""
    echo "A Gmail App Password is required for sending monitoring emails."
    echo ""
    echo "  Note: App Passwords require 2FA to be enabled on your Google account."
    echo "  To create an App Password, visit:"
    echo ""
    echo "    https://myaccount.google.com/apppasswords"
    echo ""
    echo "  Create a new app password (name it something like 'Mac Mini Server')."
    echo ""
    read -r -s -p "Enter Gmail App Password: " APP_PASSWORD
    echo ""
  fi

  if [[ -z "${APP_PASSWORD}" ]]; then
    collect_error "No App Password provided"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Section 3: Write msmtp configuration
# ---------------------------------------------------------------------------

set_section "msmtp Configuration"

if [[ "${APP_PASSWORD:-}" == "__EXISTING__" ]]; then
  log "Keeping existing msmtp configuration"
else
  # Create directories as operator
  sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${MSMTP_CONFIG_DIR}"
  sudo -iu "${OPERATOR_USERNAME}" mkdir -p "$(dirname "${MSMTP_LOG}")"

  # Write config with embedded password (mode 600, owned by operator).
  # This follows the same credential-embedding pattern used by other services
  # in this repo (see docs/keychain-credential-management.md). The operator
  # keychain cannot be unlocked from non-interactive contexts (LaunchAgents,
  # sudo -iu), so credentials are embedded in config files with restrictive
  # permissions instead.
  #
  # Note on 'from' address: Gmail overrides this with the authenticated sender.
  # The operator@hostname value is cosmetic and won't appear in delivered mail.

  # Write to temp file first, then move (atomic)
  local_tmp=$(mktemp)
  cat >"${local_tmp}" <<EOF
# msmtp configuration for ${HOSTNAME} monitoring
# Generated by msmtp-setup.sh on $(date '+%Y-%m-%d')
#
# Gmail will override the 'from' field with the authenticated sender address.
# The ${OPERATOR_USERNAME}@${HOSTNAME_LOWER} value below is cosmetic only.
#
# SECURITY: This file contains an embedded App Password.
# Permissions must remain 600, owned by ${OPERATOR_USERNAME}.

defaults
auth           on
tls            on
tls_trust_file /etc/ssl/cert.pem
logfile        ${MSMTP_LOG}

account        gmail
host           smtp.gmail.com
port           587
from           ${OPERATOR_USERNAME}@${HOSTNAME_LOWER}
user           ${MONITORING_EMAIL}
password       ${APP_PASSWORD}

account default : gmail
EOF

  # Deploy as operator with restrictive permissions
  sudo cp "${local_tmp}" "${MSMTP_CONFIG}"
  sudo chown "${OPERATOR_USERNAME}:staff" "${MSMTP_CONFIG}"
  sudo chmod 600 "${MSMTP_CONFIG}"
  rm -f "${local_tmp}"

  # Clear password from memory
  APP_PASSWORD="REDACTED"

  log "msmtp configuration written to ${MSMTP_CONFIG} (mode 600, owner: ${OPERATOR_USERNAME})"
fi

# ---------------------------------------------------------------------------
# Section 4: Send test email
# ---------------------------------------------------------------------------

set_section "Test Email"

log "Sending test email to ${MONITORING_EMAIL}..."

TEST_SUBJECT="[${HOSTNAME}] Monitoring email configured"
TEST_BODY="This is a test email from the ${HOSTNAME} Mac Mini server.

msmtp has been configured successfully. This email facility is available
for any monitoring or alerting script on this server.

Sent: $(date '+%Y-%m-%d %H:%M:%S %Z')
Host: ${HOSTNAME}
From: msmtp-setup.sh"

# Send as operator to verify the full chain works as it will at runtime
if printf "Subject: %s\nTo: %s\n\n%s\n" "${TEST_SUBJECT}" "${MONITORING_EMAIL}" "${TEST_BODY}" \
  | sudo -iu "${OPERATOR_USERNAME}" msmtp -C "${MSMTP_CONFIG}" "${MONITORING_EMAIL}"; then
  log "Test email sent successfully to ${MONITORING_EMAIL}"
else
  collect_error "Failed to send test email — check App Password and Gmail settings"
  exit 1
fi

log ""
log "msmtp setup complete. Any script running as ${OPERATOR_USERNAME} can now send email via:"
log "  echo 'body' | msmtp -C ${MSMTP_CONFIG} ${MONITORING_EMAIL}"
