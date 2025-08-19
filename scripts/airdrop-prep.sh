#!/usr/bin/env bash
#
# airdrop-prep.sh - Script to prepare a directory with necessary files for Mac Mini M2 server setup
#
# This script prepares a directory with all the necessary scripts and files
# for setting up the Mac Mini M2 server. After running, AirDrop the entire directory
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
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
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
fi

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

echo "====== Preparing ${SERVER_NAME} Server Setup Files for AirDrop ======"
echo "Output path: ${OUTPUT_PATH}"
echo -n "Date: "
date

# Create directory structure
echo "Creating directory structure..."
mkdir -p "${OUTPUT_PATH}/ssh_keys"
mkdir -p "${OUTPUT_PATH}/scripts"
mkdir -p "${OUTPUT_PATH}/scripts/app-setup"
mkdir -p "${OUTPUT_PATH}/pam.d"
mkdir -p "${OUTPUT_PATH}/config"

# Generate development machine fingerprint to prevent accidental execution
DEV_FINGERPRINT=$(system_profiler SPHardwareDataType | grep "Hardware UUID" | awk '{print $3}')
if [[ -n "${DEV_FINGERPRINT}" ]]; then
  echo "Development machine fingerprint: ${DEV_FINGERPRINT}"
  echo "DEV_MACHINE_FINGERPRINT=\"${DEV_FINGERPRINT}\"" >"${OUTPUT_PATH}/config/dev_fingerprint.conf"
  chmod 600 "${OUTPUT_PATH}/config/dev_fingerprint.conf"
  echo "Development fingerprint saved to prevent accidental execution on this machine"
else
  echo "❌ Could not generate development machine fingerprint"
  exit 1
fi

# Remove existing server host key if any
ssh-keygen -R "${SERVER_NAME_LOWER}".local

# Copy SSH keys
SSH_PUBLIC_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"
SSH_PRIVATE_KEY_PATH="${HOME}/.ssh/id_ed25519"

if [[ -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
  echo "Copying SSH public key..."
  cp "${SSH_PUBLIC_KEY_PATH}" "${OUTPUT_PATH}/ssh_keys/authorized_keys"
  cp "${SSH_PUBLIC_KEY_PATH}" "${OUTPUT_PATH}/ssh_keys/id_ed25519.pub"

  # Create operator keys (same as admin for now)
  cp "${SSH_PUBLIC_KEY_PATH}" "${OUTPUT_PATH}/ssh_keys/operator_authorized_keys"
else
  echo "Warning: SSH public key not found at ${SSH_PUBLIC_KEY_PATH}"
  echo "Please generate SSH keys or specify the correct path"
fi

if [[ -f "${SSH_PRIVATE_KEY_PATH}" ]]; then
  echo "Copying SSH private key..."
  cp "${SSH_PRIVATE_KEY_PATH}" "${OUTPUT_PATH}/ssh_keys/id_ed25519"
  chmod 600 "${OUTPUT_PATH}/ssh_keys/id_ed25519"
else
  echo "Warning: SSH private key not found at ${SSH_PRIVATE_KEY_PATH}"
  echo "Private key will not be available on the server"
fi

# TouchID sudo configuration setup
echo ""
echo "====== TouchID Sudo Configuration ======"
read -p "Enable TouchID for sudo authentication on the server? (Y/n) " -n 1 -r TOUCHID_CHOICE
echo ""

if [[ -z "${TOUCHID_CHOICE}" ]] || [[ ${TOUCHID_CHOICE} =~ ^[Yy]$ ]]; then
  echo "Creating TouchID sudo configuration file for server setup..."
  cat >"${OUTPUT_PATH}/pam.d/sudo_local" <<'EOF'
# sudo_local: PAM configuration for enabling TouchID for sudo
#
# This file enables the use of TouchID as an authentication method for sudo
# commands on macOS. It is used in addition to the standard sudo configuration.
#
# Format: auth sufficient pam_tid.so

# Allow TouchID authentication for sudo
auth       sufficient     pam_tid.so
EOF
  chmod 644 "${OUTPUT_PATH}/pam.d/sudo_local"
  echo "✅ TouchID sudo configuration created for transfer"
else
  echo "Skipping TouchID sudo setup - standard password authentication will be used"
fi

# WiFi Configuration Strategy Selection
echo ""
echo "====== WiFi Network Configuration Strategy ======"
echo "Choose your WiFi setup method:"
echo "1. Migration Assistant iPhone/iPad option (recommended - handles WiFi automatically)"
echo "2. Script-based WiFi configuration (retrieves current network credentials)"
echo ""
read -p "Will you use Migration Assistant's iPhone/iPad option for WiFi? (Y/n) " -n 1 -r WIFI_STRATEGY
echo ""

if [[ ${WIFI_STRATEGY} =~ ^[Nn]$ ]]; then
  echo "Selected: Script-based WiFi configuration"
  echo "Getting current WiFi network information..."
  CURRENT_SSID=$(system_profiler SPAirPortDataType | awk '/Current Network/ {getline;$1=$1;print $0 | "tr -d \":\"";exit}' || true)

  if [[ -n "${CURRENT_SSID}" ]]; then
    echo "Current WiFi network SSID: ${CURRENT_SSID}"

    echo "Retrieving WiFi password..."
    echo "You'll be prompted for your administrator password to access the keychain."
    WIFI_PASSWORD=$(security find-generic-password -a "${CURRENT_SSID}" -w "/Library/Keychains/System.keychain")

    if [[ -n "${WIFI_PASSWORD}" ]]; then
      echo "WiFi password retrieved successfully."

      # Save WiFi information securely in config directory
      cat >"${OUTPUT_PATH}/config/wifi_network.conf" <<EOF
WIFI_SSID="${CURRENT_SSID}"
WIFI_PASSWORD="${WIFI_PASSWORD}"
EOF
      chmod 600 "${OUTPUT_PATH}/config/wifi_network.conf"
      echo "WiFi network configuration saved to config/wifi_network.conf"
    else
      echo "Error: Could not retrieve WiFi password."
      echo "WiFi network configuration will not be automated."
    fi
  else
    echo "Warning: Could not detect current WiFi network."
    echo "WiFi network configuration will not be automated."
  fi
else
  echo "Selected: Migration Assistant WiFi configuration"
  echo "✅ Migration Assistant will handle WiFi network setup automatically"
  echo "No WiFi credentials will be transferred to the setup package"
fi

# Set up operator account credentials using 1Password
echo "Setting up operator account credentials..."

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

# Retrieve the operator password and save it for transfer
echo "Retrieving operator password from 1Password..."
op read "op://${ONEPASSWORD_VAULT}/${ONEPASSWORD_OPERATOR_ITEM}/password" >"${OUTPUT_PATH}/config/operator_password"
chmod 600 "${OUTPUT_PATH}/config/operator_password"
echo "✅ Operator password saved for transfer"

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

  # Create Time Machine configuration file
  cat >"${OUTPUT_PATH}/config/timemachine.conf" <<EOF
TM_USERNAME="${TM_USERNAME}"
TM_PASSWORD="${TM_PASSWORD}"
TM_URL="${TM_URL}"
EOF
  chmod 600 "${OUTPUT_PATH}/config/timemachine.conf"
  echo "✅ Time Machine configuration saved for transfer"
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

  # Create Plex NAS configuration file in app-setup directory
  cat >"${OUTPUT_PATH}/scripts/app-setup/plex_nas.conf" <<EOF
PLEX_NAS_USERNAME="${PLEX_NAS_USERNAME}"
PLEX_NAS_PASSWORD="${PLEX_NAS_PASSWORD}"
PLEX_NAS_HOSTNAME="${PLEX_NAS_HOSTNAME}"
EOF
  chmod 600 "${OUTPUT_PATH}/scripts/app-setup/plex_nas.conf"
  echo "✅ Plex NAS configuration saved for transfer"
fi

# Create and save one-time link for Apple ID password
APPLE_ID_ITEM="$(op item list --categories Login --vault "${ONEPASSWORD_VAULT}" --favorite --format=json | jq -r '.[] | select(.title == "'"${ONEPASSWORD_APPLEID_ITEM}"'") | .id' || true)"
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

# Copy dock cleanup script for operator
if [[ -f "${SCRIPT_SOURCE_DIR}/scripts/dock-cleanup.command" ]]; then
  echo "Copying operator dock cleanup script"
  cp "${SCRIPT_SOURCE_DIR}/scripts/dock-cleanup.command" "${OUTPUT_PATH}/scripts/"
  chmod +x "${OUTPUT_PATH}/scripts/dock-cleanup.command"
fi

# Copy from local script source directory
if [[ -d "${SCRIPT_SOURCE_DIR}" ]]; then
  echo "Copying scripts from local source directory..."

  # Copy scripts
  cp "${SCRIPT_SOURCE_DIR}/scripts/first-boot.sh" "${OUTPUT_PATH}/scripts/" 2>/dev/null || echo "Warning: first-boot.sh not found in source directory"
  cp "${SCRIPT_SOURCE_DIR}/scripts/mount-nas-media.sh" "${OUTPUT_PATH}/scripts/" 2>/dev/null || echo "Warning: mount-nas-media.sh not found in source directory"
  cp "${SCRIPT_SOURCE_DIR}/app-setup/"*.sh "${OUTPUT_PATH}/scripts/app-setup/" 2>/dev/null || echo "Warning: No app setup scripts found in source directory"
  cp "${SCRIPT_SOURCE_DIR}/config/formulae.txt" "${OUTPUT_PATH}/config/" 2>/dev/null || echo "Warning: formulae.txt not found in source directory"
  cp "${SCRIPT_SOURCE_DIR}/config/casks.txt" "${OUTPUT_PATH}/config/" 2>/dev/null || echo "Warning: casks.txt not found in source directory"

  # Copy configuration file if it exists
  if [[ -f "${CONFIG_FILE}" ]]; then
    cp "${CONFIG_FILE}" "${OUTPUT_PATH}/config/"
    echo "Configuration file copied to setup package"
  fi

  echo "Scripts copied from local source directory"
else
  echo "Error: No script source found. Please provide a local script source directory."
  exit 1
fi

# Copy README with variable substitution
if [[ -f "${SCRIPT_SOURCE_DIR}/docs/setup/README-firstboot.md" ]]; then
  echo "Processing README file..."
  sed "s/\${SERVER_NAME_LOWER}/${SERVER_NAME_LOWER}/g" \
    "${SCRIPT_SOURCE_DIR}/docs/setup/README-firstboot.md" >"${OUTPUT_PATH}/README.md"
  echo "✅ README creation"
else
  echo "⚠️ README-firstboot.md not found in source directory"
fi

echo "Setting file permissions..."
chmod -R 755 "${OUTPUT_PATH}/scripts"
chmod 600 "${OUTPUT_PATH}/config/"* 2>/dev/null || true

echo "====== Setup Files Preparation Complete ======"
echo "The setup files at ${OUTPUT_PATH} are now ready for AirDrop."
echo "AirDrop this entire folder to your Mac Mini after completing the macOS setup wizard"
echo "and run the first-boot.sh script from the transferred directory."

open "${OUTPUT_PATH}"

exit 0
