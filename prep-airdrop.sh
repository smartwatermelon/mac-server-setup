#!/usr/bin/env bash

#
# airdrop-prep.sh - Script to prepare a directory with necessary files for Mac Mini server setup
#
# This script prepares a directory with all the necessary scripts and files
# for setting up the Mac Mini server. After running, AirDrop the entire directory
# to your new Mac Mini.
#
# Usage: ./airdrop-prep.sh [output_path] [script_path]
#	output_path: Path where the files will be created (default: ~/macmini-setup)
#
# Author: Claude
# Version: 1.3
# Created: 2025-05-13

# Exit on error
set -euo pipefail

# Configuration
SCRIPT_SOURCE_DIR="${2:-.}" # Directory containing source scripts (default is current dir)

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}" # Script is now at repo root
CONFIG_DIR="${PROJECT_ROOT}/config"
CONFIG_FILE="${CONFIG_DIR}/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  echo "Loaded configuration from ${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  SERVER_NAME="MACMINI"
  ONEPASSWORD_VAULT="personal"
  ONEPASSWORD_OPERATOR_ITEM="operator"
  ONEPASSWORD_TIMEMACHINE_ITEM="TimeMachine"
  ONEPASSWORD_PLEX_NAS_ITEM="Plex NAS"
  ONEPASSWORD_APPLEID_ITEM="Apple"
  DROPBOX_SYNC_FOLDER=""
  DROPBOX_LOCAL_PATH=""
fi

# Handle command line arguments
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
  echo "Usage: $(basename "$0") [output_path] [script_path]"
  echo ""
  echo "Prepares setup files for Mac Mini server deployment."
  echo ""
  echo "Arguments:"
  echo "  output_path    Directory where setup files will be created (default: ~/${SERVER_NAME_LOWER:-server}-setup)"
  echo "  script_path    Source directory containing scripts (default: current directory)"
  echo ""
  echo "The prepared directory can be AirDropped to your Mac Mini for setup."
  exit 0
fi

# Error and warning collection system
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
CURRENT_SCRIPT_SECTION=""

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  echo "====== $1 ======"
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

  echo "❌ ${clean_message}"
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

  echo "⚠️ ${clean_message}"
  COLLECTED_WARNINGS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to show collected errors and warnings at end
show_collected_issues() {
  local error_count=${#COLLECTED_ERRORS[@]}
  local warning_count=${#COLLECTED_WARNINGS[@]}

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    echo "✅ AirDrop preparation completed successfully with no errors or warnings!"
    return
  fi

  echo ""
  echo "====== AIRDROP PREPARATION SUMMARY ======"
  echo "Preparation completed, but ${error_count} errors and ${warning_count} warnings occurred:"
  echo ""

  if [[ ${error_count} -gt 0 ]]; then
    echo "ERRORS:"
    for error in "${COLLECTED_ERRORS[@]}"; do
      echo "  ${error}"
    done
    echo ""
  fi

  if [[ ${warning_count} -gt 0 ]]; then
    echo "WARNINGS:"
    for warning in "${COLLECTED_WARNINGS[@]}"; do
      echo "  ${warning}"
    done
    echo ""
  fi

  echo "Review issues above - some warnings may be expected if optional components are missing."
}

# Set derived variables
SERVER_NAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
OUTPUT_PATH="${1:-${HOME}/${SERVER_NAME_LOWER}-setup}"
OP_TIMEMACHINE_ENTRY="${ONEPASSWORD_TIMEMACHINE_ITEM}"
OP_PLEX_NAS_ENTRY="${ONEPASSWORD_PLEX_NAS_ITEM}"

# Check if output directory exists
if [[ -d "${OUTPUT_PATH}" ]]; then
  echo "Output directory already exists: ${OUTPUT_PATH}"
  echo "This directory contains files from a previous preparation run."
  read -p "Remove existing directory and recreate? (y/N) " -n 1 -r
  echo
  if [[ ${REPLY} =~ ^[Yy]$ ]]; then
    echo "Removing existing directory..."
    rm -rf "${OUTPUT_PATH}"
    echo "Creating fresh output directory: ${OUTPUT_PATH}"
    mkdir -p "${OUTPUT_PATH}"
  else
    echo "Keeping existing directory. Files may be overwritten during preparation."
  fi
else
  echo "Creating output directory: ${OUTPUT_PATH}"
  mkdir -p "${OUTPUT_PATH}"
fi

set_section "Preparing ${SERVER_NAME} Server Setup Files for AirDrop"
echo "Output path: ${OUTPUT_PATH}"
echo -n "Date: "
date

# Create directory structure
set_section "Creating Directory Structure"
mkdir -p "${OUTPUT_PATH}/ssh_keys"
mkdir -p "${OUTPUT_PATH}/scripts"
mkdir -p "${OUTPUT_PATH}/app-setup/config"
mkdir -p "${OUTPUT_PATH}/app-setup/templates"
mkdir -p "${OUTPUT_PATH}/config"

# Generate development machine fingerprint to prevent accidental execution
DEV_FINGERPRINT=$(system_profiler SPHardwareDataType | grep "Hardware UUID" | awk '{print $3}')
if [[ -n "${DEV_FINGERPRINT}" ]]; then
  echo "Development machine fingerprint: ${DEV_FINGERPRINT}"
  echo "DEV_MACHINE_FINGERPRINT=\"${DEV_FINGERPRINT}\"" >"${OUTPUT_PATH}/config/dev_fingerprint.conf"
  chmod 600 "${OUTPUT_PATH}/config/dev_fingerprint.conf"
  echo "Development fingerprint saved to prevent accidental execution on this machine"
else
  collect_error "Could not generate development machine fingerprint"
  exit 1
fi

# Remove existing server host key if any
ssh-keygen -R "${SERVER_NAME_LOWER}".local

# Copy SSH keys
set_section "Copying SSH Keys"
SSH_PUBLIC_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"
SSH_PRIVATE_KEY_PATH="${HOME}/.ssh/id_ed25519"

if [[ -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
  echo "Copying SSH public key..."
  cp "${SSH_PUBLIC_KEY_PATH}" "${OUTPUT_PATH}/ssh_keys/authorized_keys"
  cp "${SSH_PUBLIC_KEY_PATH}" "${OUTPUT_PATH}/ssh_keys/id_ed25519.pub"

  # Create operator keys (same as admin for now)
  cp "${SSH_PUBLIC_KEY_PATH}" "${OUTPUT_PATH}/ssh_keys/operator_authorized_keys"
else
  collect_warning "SSH public key not found at ${SSH_PUBLIC_KEY_PATH}"
  echo "Please generate SSH keys or specify the correct path"
fi

if [[ -f "${SSH_PRIVATE_KEY_PATH}" ]]; then
  echo "Copying SSH private key..."
  cp "${SSH_PRIVATE_KEY_PATH}" "${OUTPUT_PATH}/ssh_keys/id_ed25519"
  chmod 600 "${OUTPUT_PATH}/ssh_keys/id_ed25519"
else
  collect_warning "SSH private key not found at ${SSH_PRIVATE_KEY_PATH}"
  echo "Private key will not be available on the server"
fi

# WiFi Configuration Strategy Selection
set_section "WiFi Network Configuration Strategy"
echo "Choose your WiFi setup method:"
echo "1. Migration Assistant iPhone/iPad option (recommended - handles WiFi automatically)"
echo "2. Script-based WiFi configuration (retrieves current network credentials)"
echo ""
read -p "Will you use Migration Assistant's iPhone/iPad option for WiFi? (Y/n) " -n 1 -r WIFI_STRATEGY
echo ""

if [[ ${WIFI_STRATEGY} =~ ^[Nn]$ ]]; then
  echo "Selected: Script-based WiFi configuration"
  echo "Getting current WiFi network information..."
  CURRENT_SSID=$(system_profiler SPAirPortDataType | awk '/Current Network/ {getline;$1=$1;print $0 | "tr -d \":\"";exit}' 2>/dev/null || echo "")

  if [[ -n "${CURRENT_SSID}" ]]; then
    echo "Current WiFi network SSID: ${CURRENT_SSID}"

    echo "Retrieving WiFi password..."
    echo "You'll be prompted for your administrator password to access the keychain."
    WIFI_PASSWORD=$(security find-generic-password -a "${CURRENT_SSID}" -w "/Library/Keychains/System.keychain")

    if [[ -n "${WIFI_PASSWORD}" ]]; then
      echo "WiFi password retrieved successfully."

      # Store WiFi credentials in Keychain
      store_keychain_credential \
        "mac-server-setup-wifi-${SERVER_NAME_LOWER}" \
        "${SERVER_NAME_LOWER}" \
        "${CURRENT_SSID}:${WIFI_PASSWORD}" \
        "Mac Server Setup - WiFi Credentials"

      # Create basic SSID config file (non-sensitive)
      cat >"${OUTPUT_PATH}/config/wifi_network.conf" <<EOF
WIFI_SSID="${CURRENT_SSID}"
EOF
      chmod 644 "${OUTPUT_PATH}/config/wifi_network.conf"

      # Clear password from memory
      unset WIFI_PASSWORD
      echo "WiFi credentials stored in Keychain and SSID saved to config"
    else
      collect_error "Could not retrieve WiFi password"
      echo "WiFi network configuration will not be automated."
    fi
  else
    collect_warning "Could not detect current WiFi network"
    echo "WiFi network configuration will not be automated."
  fi
else
  echo "Selected: Migration Assistant WiFi configuration"
  echo "✅ Migration Assistant will handle WiFi network setup automatically"
  echo "No WiFi credentials will be transferred to the setup package"
fi

# Keychain credential management functions
# Store credential in Keychain with immediate verification
store_keychain_credential() {
  local service="$1"
  local account="$2"
  local password="$3"
  local description="$4"

  # Delete existing credential if present (for updates)
  security delete-internet-password -s "${service}" -a "${account}" 2>/dev/null || true

  # Store in Keychain as internet password (these sync with iCloud Keychain automatically)
  # Note: -A flag allows any application access without prompting, required for LaunchAgent use
  if security add-internet-password \
    -s "${service}" \
    -a "${account}" \
    -w "${password}" \
    -D "${description}" \
    -A \
    -U; then

    # Immediately verify by reading back
    local retrieved_password
    if retrieved_password=$(security find-internet-password \
      -s "${service}" \
      -a "${account}" \
      -w 2>/dev/null); then

      if [[ "${password}" == "${retrieved_password}" ]]; then
        echo "✅ Credential stored and verified in Keychain: ${service}"
        return 0
      else
        collect_error "Keychain credential verification failed for ${service}"
        return 1
      fi
    else
      collect_error "Keychain credential verification failed for ${service}: could not retrieve"
      return 1
    fi
  else
    collect_error "Failed to store credential in Keychain: ${service}"
    return 1
  fi
}

# Create Keychain manifest for server
create_keychain_manifest() {
  cat >"${OUTPUT_PATH}/config/keychain_manifest.conf" <<EOF
# Keychain service identifiers for credential retrieval
KEYCHAIN_OPERATOR_SERVICE="mac-server-setup-operator-${SERVER_NAME_LOWER}"
KEYCHAIN_PLEX_NAS_SERVICE="mac-server-setup-plex-nas-${SERVER_NAME_LOWER}"
KEYCHAIN_TIMEMACHINE_SERVICE="mac-server-setup-timemachine-${SERVER_NAME_LOWER}"
KEYCHAIN_WIFI_SERVICE="mac-server-setup-wifi-${SERVER_NAME_LOWER}"
KEYCHAIN_ACCOUNT="${SERVER_NAME_LOWER}"
EOF
  chmod 600 "${OUTPUT_PATH}/config/keychain_manifest.conf"
  echo "✅ Keychain manifest created"
}

# Set up operator account credentials using 1Password
set_section "Setting up operator account credentials"

# Check if operator credentials exist in 1Password
if ! op item get "${ONEPASSWORD_OPERATOR_ITEM}" --vault "${ONEPASSWORD_VAULT}" >/dev/null 2>&1; then
  echo "Creating ${ONEPASSWORD_OPERATOR_ITEM} credentials in 1Password..."

  # Generate a secure password and create the item
  RANDOM_BYTES=$(openssl rand -base64 16)
  CLEANED_BYTES=$(echo "${RANDOM_BYTES}" | tr -d "=+/")
  GENERATED_PASSWORD=$(echo "${CLEANED_BYTES}" | cut -c1-20)

  op item create --category login \
    --title "${ONEPASSWORD_OPERATOR_ITEM}" \
    --vault "${ONEPASSWORD_VAULT}" \
    username="operator" \
    password="${GENERATED_PASSWORD}"

  echo "✅ Created ${ONEPASSWORD_OPERATOR_ITEM} credentials in 1Password"
else
  echo "✅ Found existing ${ONEPASSWORD_OPERATOR_ITEM} credentials in 1Password"
fi

# Retrieve the operator password and store in Keychain
echo "Retrieving operator password from 1Password..."
OPERATOR_PASSWORD=$(op read "op://${ONEPASSWORD_VAULT}/${ONEPASSWORD_OPERATOR_ITEM}/password")
store_keychain_credential \
  "mac-server-setup-operator-${SERVER_NAME_LOWER}" \
  "${SERVER_NAME_LOWER}" \
  "${OPERATOR_PASSWORD}" \
  "Mac Server Setup - Operator Account Password"

# Clear password from memory
unset OPERATOR_PASSWORD
echo "✅ Operator password stored in Keychain"

# Set up Time Machine credentials using 1Password
echo "Setting up Time Machine credentials..."

# Check if Time Machine credentials exist in 1Password
if ! op item get "${OP_TIMEMACHINE_ENTRY}" --vault "${ONEPASSWORD_VAULT}" >/dev/null 2>&1; then
  echo "⚠️ Time Machine credentials not found in 1Password"
  echo "Please create '${OP_TIMEMACHINE_ENTRY}' entry manually"
  echo "Skipping Time Machine credential setup"
else
  echo "✅ Found Time Machine credentials in 1Password"

  # Retrieve Time Machine details from 1Password
  echo "Retrieving Time Machine details from 1Password..."
  TM_USERNAME=$(op item get "${OP_TIMEMACHINE_ENTRY}" --vault "${ONEPASSWORD_VAULT}" --fields username)
  TM_PASSWORD=$(op read "op://${ONEPASSWORD_VAULT}/${OP_TIMEMACHINE_ENTRY}/password")
  TM_JSON=$(op item get "${OP_TIMEMACHINE_ENTRY}" --vault "${ONEPASSWORD_VAULT}" --format json)
  TM_URL=$(echo "${TM_JSON}" | jq -r '.urls[0].href')

  # Store TimeMachine credentials in Keychain (username:password format)
  store_keychain_credential \
    "mac-server-setup-timemachine-${SERVER_NAME_LOWER}" \
    "${SERVER_NAME_LOWER}" \
    "${TM_USERNAME}:${TM_PASSWORD}" \
    "Mac Server Setup - TimeMachine Credentials"

  # Create basic URL config file (non-sensitive)
  cat >"${OUTPUT_PATH}/config/timemachine.conf" <<EOF
TM_URL="${TM_URL}"
EOF
  chmod 644 "${OUTPUT_PATH}/config/timemachine.conf"

  # Clear credentials from memory
  unset TM_USERNAME TM_PASSWORD
  echo "✅ Time Machine credentials stored in Keychain"
fi

# Set up Plex NAS credentials using 1Password
echo "Setting up Plex NAS credentials..."

# Check if Plex NAS credentials exist in 1Password
if ! op item get "${OP_PLEX_NAS_ENTRY}" --vault "${ONEPASSWORD_VAULT}" >/dev/null 2>&1; then
  echo "⚠️ Plex NAS credentials not found in 1Password"
  echo "Please create '${OP_PLEX_NAS_ENTRY}' entry manually"
  echo "Skipping Plex NAS credential setup"
else
  echo "✅ Found Plex NAS credentials in 1Password"

  # Retrieve Plex NAS details from 1Password
  echo "Retrieving Plex NAS details from 1Password..."
  PLEX_NAS_USERNAME=$(op item get "${OP_PLEX_NAS_ENTRY}" --vault "${ONEPASSWORD_VAULT}" --fields username)
  PLEX_NAS_PASSWORD=$(op read "op://${ONEPASSWORD_VAULT}/${OP_PLEX_NAS_ENTRY}/password")
  PLEX_NAS_JSON=$(op item get "${OP_PLEX_NAS_ENTRY}" --vault "${ONEPASSWORD_VAULT}" --format json)
  PLEX_NAS_URL=$(echo "${PLEX_NAS_JSON}" | jq -r '.urls[0].href // "nas.local"')

  # Extract hostname from URL if it's a full URL, otherwise use as-is
  if [[ "${PLEX_NAS_URL}" =~ ^[a-zA-Z]+:// ]]; then
    # Extract hostname from URL (e.g., "smb://nas.local/share" -> "nas.local")
    PLEX_NAS_HOSTNAME=$(echo "${PLEX_NAS_URL}" | sed -E 's|^[^/]+//([^/]+).*|\1|')
  else
    # Use URL field directly as hostname (e.g., "nas.local")
    PLEX_NAS_HOSTNAME="${PLEX_NAS_URL}"
  fi

  # Store Plex NAS credentials in Keychain (username:password format)
  store_keychain_credential \
    "mac-server-setup-plex-nas-${SERVER_NAME_LOWER}" \
    "${SERVER_NAME_LOWER}" \
    "${PLEX_NAS_USERNAME}:${PLEX_NAS_PASSWORD}" \
    "Mac Server Setup - Plex NAS Credentials"

  # Create basic hostname config file (non-sensitive)
  cat >"${OUTPUT_PATH}/app-setup/config/plex_nas.conf" <<EOF
PLEX_NAS_HOSTNAME="${PLEX_NAS_HOSTNAME}"
EOF
  chmod 644 "${OUTPUT_PATH}/app-setup/config/plex_nas.conf"

  # Clear credentials from memory
  unset PLEX_NAS_USERNAME PLEX_NAS_PASSWORD
  echo "✅ Plex NAS credentials stored in Keychain"
fi

# Set up Dropbox synchronization if configured
if [[ -n "${DROPBOX_SYNC_FOLDER:-}" ]]; then
  if [[ -f "${SCRIPT_SOURCE_DIR}/scripts/airdrop/rclone-airdrop-prep.sh" ]]; then
    echo "Running Dropbox setup..."
    # Export required variables for the rclone script
    export OUTPUT_PATH SERVER_NAME_LOWER DROPBOX_SYNC_FOLDER DROPBOX_LOCAL_PATH
    "${SCRIPT_SOURCE_DIR}/scripts/airdrop/rclone-airdrop-prep.sh"
  else
    collect_warning "rclone-airdrop-prep.sh not found - skipping Dropbox setup"
  fi
else
  echo "No Dropbox sync folder configured - skipping Dropbox setup"
fi

# Create and save one-time link for Apple ID password
APPLE_ID_ITEM="$(op item list --categories Login --vault "${ONEPASSWORD_VAULT}" --favorite --format=json 2>/dev/null | jq -r '.[] | select(.title == "'"${ONEPASSWORD_APPLEID_ITEM}"'") | .id' 2>/dev/null || echo "")"
ONE_TIME_URL="$(op item share "${APPLE_ID_ITEM}" --view-once)"
if [[ -n "${ONE_TIME_URL}" ]]; then
  # Create the .url file with the correct format
  cat >"${OUTPUT_PATH}/config/apple_id_password.url" <<EOF
[InternetShortcut]
URL=${ONE_TIME_URL}
EOF
  chmod 600 "${OUTPUT_PATH}/config/apple_id_password.url"
  echo "✅ Apple ID one-time password link saved to config/apple_id_password.url"
else
  echo "⚠️ No URL provided, skipping Apple ID password link creation"
fi

# Copy operator first-login script
if [[ -f "${SCRIPT_SOURCE_DIR}/scripts/server/operator-first-login.sh" ]]; then
  echo "Copying operator first-login script"
  cp "${SCRIPT_SOURCE_DIR}/scripts/server/operator-first-login.sh" "${OUTPUT_PATH}/scripts/"
  chmod +x "${OUTPUT_PATH}/scripts/operator-first-login.sh"
fi

# Copy from local script source directory
if [[ -d "${SCRIPT_SOURCE_DIR}" ]]; then
  set_section "Copying scripts from local source directory"

  # Copy main entry point script to root
  cp "${SCRIPT_SOURCE_DIR}/scripts/server/first-boot.sh" "${OUTPUT_PATH}/" 2>/dev/null || collect_warning "first-boot.sh not found in server directory"

  # Copy system scripts to scripts directory
  cp "${SCRIPT_SOURCE_DIR}/scripts/server/setup-remote-desktop.sh" "${OUTPUT_PATH}/scripts/" 2>/dev/null || echo "Warning: setup-remote-desktop.sh not found in server directory"

  # Copy template scripts to app-setup/templates
  cp "${SCRIPT_SOURCE_DIR}/app-setup/app-setup-templates/mount-nas-media.sh" "${OUTPUT_PATH}/app-setup/templates/" 2>/dev/null || echo "Warning: mount-nas-media.sh not found in app-setup-templates directory"
  cp "${SCRIPT_SOURCE_DIR}/app-setup/app-setup-templates/start-plex-with-mount.sh" "${OUTPUT_PATH}/app-setup/templates/" 2>/dev/null || echo "Warning: start-plex-with-mount.sh not found in app-setup-templates directory"
  cp "${SCRIPT_SOURCE_DIR}/app-setup/app-setup-templates/start-rclone.sh" "${OUTPUT_PATH}/app-setup/templates/" 2>/dev/null || echo "Warning: start-rclone.sh not found in app-setup-templates directory"

  # Copy app setup scripts to app-setup directory
  cp "${SCRIPT_SOURCE_DIR}/app-setup/"*.sh "${OUTPUT_PATH}/app-setup/" 2>/dev/null || echo "Warning: No app setup scripts found in source directory"

  # Copy system configuration files
  cp "${SCRIPT_SOURCE_DIR}/config/formulae.txt" "${OUTPUT_PATH}/config/" 2>/dev/null || echo "Warning: formulae.txt not found in source directory"
  cp "${SCRIPT_SOURCE_DIR}/config/casks.txt" "${OUTPUT_PATH}/config/" 2>/dev/null || echo "Warning: casks.txt not found in source directory"
  cp "${SCRIPT_SOURCE_DIR}/config/logrotate.conf" "${OUTPUT_PATH}/config/" 2>/dev/null || echo "Warning: logrotate.conf not found in source directory"

  # Copy configuration file if it exists
  if [[ -f "${CONFIG_FILE}" ]]; then
    cp "${CONFIG_FILE}" "${OUTPUT_PATH}/config/"
    echo "Configuration file copied to setup package"
  fi

  echo "Scripts copied from local source directory"
else
  collect_error "No script source found. Please provide a local script source directory."
  exit 1
fi

# Copy README with variable substitution
if [[ -f "${SCRIPT_SOURCE_DIR}/docs/setup/firstboot-README.md" ]]; then
  echo "Processing README file..."
  sed "s/\${SERVER_NAME_LOWER}/${SERVER_NAME_LOWER}/g" \
    "${SCRIPT_SOURCE_DIR}/docs/setup/firstboot-README.md" >"${OUTPUT_PATH}/README.md"
  echo "✅ README creation"
else
  echo "⚠️ firstboot-README.md not found in source directory"
fi

echo "Setting file permissions..."
chmod 755 "${OUTPUT_PATH}/first-boot.sh" 2>/dev/null || true
chmod -R 755 "${OUTPUT_PATH}/scripts"
chmod -R 755 "${OUTPUT_PATH}/app-setup"
chmod 600 "${OUTPUT_PATH}/config/"* 2>/dev/null || true
chmod 600 "${OUTPUT_PATH}/app-setup/config/"* 2>/dev/null || true

# Create Keychain manifest for server-side credential access
create_keychain_manifest

# Show collected errors and warnings
show_collected_issues

echo ""
echo "====== Setup Files Preparation Complete ======"
echo "The setup files at ${OUTPUT_PATH} are now ready for AirDrop."
echo "AirDrop this entire folder to your Mac Mini after completing the macOS setup wizard"
echo "and run ./first-boot.sh from the transferred directory root."

open "${OUTPUT_PATH}"

exit 0
