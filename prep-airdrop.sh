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
  ONEPASSWORD_PLEX_ITEM="Plex"
  ONEPASSWORD_APPLEID_ITEM="Apple"
  ONEPASSWORD_OPENSUBTITLES_ITEM="Opensubtitles"
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

# Deploy Package Manifest Functions
# These functions create and maintain a manifest of all files in the deploy package
# to enable validation on the target server before deployment begins
# Note: copy_with_manifest and copy_dir_with_manifest will be used in subsequent integration

# Initialize deployment package manifest
init_manifest() {
  local manifest_file="${OUTPUT_PATH}/DEPLOY_MANIFEST.txt"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cat >"${manifest_file}" <<EOF
# DEPLOY_MANIFEST.txt - Generated by prep-airdrop.sh
# This file lists all files that should be present in the deployment package
# Format: relative_path=REQUIRED|OPTIONAL|MISSING
MANIFEST_VERSION=1.0
CREATED_BY=prep-airdrop.sh
CREATED_AT=${timestamp}
PACKAGE_ROOT=${OUTPUT_PATH}

EOF
  echo "📋 Initialized deploy manifest: ${manifest_file}"
}

# Add file entry to manifest
add_to_manifest() {
  local file_path="$1"   # Relative path from OUTPUT_PATH
  local requirement="$2" # REQUIRED, OPTIONAL, or MISSING
  local manifest_file="${OUTPUT_PATH}/DEPLOY_MANIFEST.txt"

  echo "${file_path}=${requirement}" >>"${manifest_file}"
}

# Remove file entry from manifest
remove_from_manifest() {
  local file_path="$1"   # Relative path from OUTPUT_PATH
  local requirement="$2" # REQUIRED, OPTIONAL, or MISSING
  local manifest_file="${OUTPUT_PATH}/DEPLOY_MANIFEST.txt"

  if [[ ! -f "${manifest_file}" ]]; then
    echo "Manifest file does not exist: ${manifest_file}"
    return 1
  fi

  # Form the line to remove
  local entry="${file_path}=${requirement}"

  # Safely remove the exact matching line
  # (using a temp file to ensure atomic operation)
  local tmpfile
  tmpfile="$(mktemp "${manifest_file}.XXXXXX")"

  grep -vxF -- "${entry}" "${manifest_file}" >"${tmpfile}" && mv "${tmpfile}" "${manifest_file}"
}

# Copy file with manifest tracking
copy_with_manifest() {
  local source="$1"
  local dest_relative="$2" # Relative to OUTPUT_PATH
  local requirement="$3"   # REQUIRED or OPTIONAL

  local dest_full="${OUTPUT_PATH}/${dest_relative}"

  if [[ -f "${source}" ]]; then
    mkdir -p "$(dirname "${dest_full}")"
    cp "${source}" "${dest_full}"
    add_to_manifest "${dest_relative}" "${requirement}"
    echo "✅ Copied to manifest: ${dest_relative}"
  else
    if [[ "${requirement}" == "REQUIRED" ]]; then
      collect_error "Required file not found for deployment: ${source}"
      add_to_manifest "${dest_relative}" "MISSING"
    else
      collect_warning "Optional file not found: ${source}"
      add_to_manifest "${dest_relative}" "MISSING"
    fi
  fi
}

copy_dir_with_manifest() {
  local source_dir="$1"
  local dest_dir_relative="$2"      # Relative to OUTPUT_PATH
  local requirement="$3"            # REQUIRED or OPTIONAL
  local except_dirs_string="${4:-}" # e.g. ".git|.claude|tmp" or ""

  local dest_dir_full="${OUTPUT_PATH}/${dest_dir_relative}"

  # Prepare array of exception dirs if except_dirs_string is non-empty
  local IFS='|'
  read -r -a except_dirs <<<"${except_dirs_string}"

  if [[ -d "${source_dir}" ]]; then
    mkdir -p "${dest_dir_full}"

    # Copy directory contents and track individual files
    if find "${source_dir}" -type f -print0 | while IFS= read -r -d '' file; do
      local relative_to_source="${file#"${source_dir}/"}"
      local skip_file=0

      # For each file, check if it matches any exclude directory
      for exclude in "${except_dirs[@]}"; do
        # Only skip if file is inside an excluded dir (prefix match)
        if [[ "${relative_to_source}" == "${exclude}/"* ]] || [[ "${relative_to_source}" == "${exclude}" ]]; then
          skip_file=1
          break
        fi
      done

      if [[ ${skip_file} -eq 1 ]]; then
        continue
      fi

      local dest_file="${dest_dir_full}/${relative_to_source}"

      mkdir -p "$(dirname "${dest_file}")"
      cp "${file}" "${dest_file}"
      add_to_manifest "${dest_dir_relative}/${relative_to_source}" "${requirement}"
    done; then
      echo "✅ Copied directory to manifest: ${dest_dir_relative}/"
    else
      if [[ "${requirement}" == "REQUIRED" ]]; then
        collect_error "Failed to copy required directory: ${source_dir}"
      else
        collect_warning "Failed to copy optional directory: ${source_dir}"
      fi
    fi
  else
    if [[ "${requirement}" == "REQUIRED" ]]; then
      collect_error "Required directory not found for deployment: ${source_dir}"
    else
      collect_warning "Optional directory not found: ${source_dir}"
    fi
  fi
}

# Set derived variables
SERVER_NAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
OUTPUT_PATH="${1:-${HOME}/${SERVER_NAME_LOWER}-setup}"
OP_TIMEMACHINE_ENTRY="${ONEPASSWORD_TIMEMACHINE_ITEM}"
OP_PLEX_NAS_ENTRY="${ONEPASSWORD_PLEX_NAS_ITEM}"
OP_OPENSUBTITLES_ENTRY="${ONEPASSWORD_OPENSUBTITLES_ITEM}"

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
mkdir -p "${OUTPUT_PATH}/bash"

# Initialize deployment package manifest
init_manifest

# Generate development machine fingerprint to prevent accidental execution
DEV_FINGERPRINT=$(system_profiler SPHardwareDataType | grep "Hardware UUID" | awk '{print $3}')
if [[ -n "${DEV_FINGERPRINT}" ]]; then
  echo "Development machine fingerprint: ${DEV_FINGERPRINT}"
  echo "DEV_MACHINE_FINGERPRINT=\"${DEV_FINGERPRINT}\"" >"${OUTPUT_PATH}/config/dev_fingerprint.conf"
  chmod 600 "${OUTPUT_PATH}/config/dev_fingerprint.conf"
  add_to_manifest "config/dev_fingerprint.conf" "REQUIRED"
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

echo "Copying SSH keys..."
copy_with_manifest "${SSH_PUBLIC_KEY_PATH}" "ssh_keys/authorized_keys" "REQUIRED"
copy_with_manifest "${SSH_PUBLIC_KEY_PATH}" "ssh_keys/id_ed25519.pub" "REQUIRED"
copy_with_manifest "${SSH_PUBLIC_KEY_PATH}" "ssh_keys/operator_authorized_keys" "REQUIRED"
copy_with_manifest "${SSH_PRIVATE_KEY_PATH}" "ssh_keys/id_ed25519" "REQUIRED"

# Set correct permissions on private key if it was copied
if [[ -f "${OUTPUT_PATH}/ssh_keys/id_ed25519" ]]; then
  chmod 600 "${OUTPUT_PATH}/ssh_keys/id_ed25519"
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

      # Store WiFi credentials in external keychain
      store_external_keychain_credential \
        "wifi-${SERVER_NAME_LOWER}" \
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

# External keychain credential management functions
# Create and manage external keychain for credential transfer

# Initialize external keychain for credential storage
init_external_keychain() {
  # Use existing dev machine fingerprint as keychain password (dynamically generated, not hardcoded)
  KEYCHAIN_PASSWORD="${DEV_FINGERPRINT}"
  EXTERNAL_KEYCHAIN="mac-server-setup"

  echo "Initializing external keychain for credential transfer..."

  # Delete existing keychain if present
  security delete-keychain "${EXTERNAL_KEYCHAIN}" 2>/dev/null || true

  # Create new external keychain
  if security create-keychain -p "${KEYCHAIN_PASSWORD}" "${EXTERNAL_KEYCHAIN}"; then
    echo "✅ External keychain created"
  else
    collect_error "Failed to create external keychain"
    return 1
  fi

  # Unlock the keychain for credential storage
  if security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${EXTERNAL_KEYCHAIN}"; then
    echo "✅ External keychain unlocked for credential storage"
  else
    collect_error "Failed to unlock external keychain"
    return 1
  fi

  return 0
}

# Store credential in external keychain with immediate verification
store_external_keychain_credential() {
  local service="$1"
  local account="$2"
  local password="$3"
  local description="$4"

  # Delete existing credential if present (for updates)
  security delete-generic-password -s "${service}" -a "${account}" "${EXTERNAL_KEYCHAIN}" 2>/dev/null || true

  # Store in external keychain
  # Note: -A flag allows any application access without prompting, required for transfer
  if security add-generic-password \
    -s "${service}" \
    -a "${account}" \
    -w "${password}" \
    -D "${description}" \
    -A \
    -U \
    "${EXTERNAL_KEYCHAIN}"; then

    # Immediately verify by reading back from external keychain
    local retrieved_password
    if retrieved_password=$(security find-generic-password \
      -s "${service}" \
      -a "${account}" \
      -w \
      "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then

      if [[ "${password}" == "${retrieved_password}" ]]; then
        echo "✅ Credential stored and verified in external keychain: ${service}"
        return 0
      else
        collect_error "External keychain credential verification failed for ${service}"
        return 1
      fi
    else
      collect_error "External keychain credential verification failed for ${service}: could not retrieve"
      return 1
    fi
  else
    collect_error "Failed to store credential in external keychain: ${service}"
    return 1
  fi
}

# Finalize external keychain and add to airdrop package
finalize_external_keychain() {
  echo "Finalizing external keychain for transfer..."

  # Lock the external keychain
  security lock-keychain "${EXTERNAL_KEYCHAIN}"

  # Get the keychain file path (macOS creates keychains with -db suffix)
  local keychain_file="${HOME}/Library/Keychains/${EXTERNAL_KEYCHAIN}-db"

  if [[ -f "${keychain_file}" ]]; then
    # Copy keychain file to airdrop package
    copy_with_manifest "${keychain_file}" "config/${EXTERNAL_KEYCHAIN}-db" "REQUIRED"
    chmod 600 "${OUTPUT_PATH}/config/${EXTERNAL_KEYCHAIN}-db"

    echo "✅ External keychain added to airdrop package"
    echo "   Keychain file: ${EXTERNAL_KEYCHAIN}-db"
    echo "   Password: Hardware UUID fingerprint"

    # Store keychain password in manifest for server use
    echo "KEYCHAIN_PASSWORD=\"${KEYCHAIN_PASSWORD}\"" >>"${OUTPUT_PATH}/config/keychain_manifest.conf"
    echo "EXTERNAL_KEYCHAIN=\"${EXTERNAL_KEYCHAIN}\"" >>"${OUTPUT_PATH}/config/keychain_manifest.conf"

    return 0
  else
    collect_error "External keychain file not found: ${keychain_file}"
    return 1
  fi
}

# Create Keychain manifest for server
create_keychain_manifest() {
  cat >"${OUTPUT_PATH}/config/keychain_manifest.conf" <<EOF
# External keychain service identifiers for credential retrieval
KEYCHAIN_OPERATOR_SERVICE="operator-${SERVER_NAME_LOWER}"
KEYCHAIN_PLEX_NAS_SERVICE="plex-nas-${SERVER_NAME_LOWER}"
KEYCHAIN_PLEX_TOKEN_SERVICE="plex-token-${SERVER_NAME_LOWER}"
KEYCHAIN_TIMEMACHINE_SERVICE="timemachine-${SERVER_NAME_LOWER}"
KEYCHAIN_WIFI_SERVICE="wifi-${SERVER_NAME_LOWER}"
KEYCHAIN_OPENSUBTITLES_SERVICE="opensubtitles-${SERVER_NAME_LOWER}"
KEYCHAIN_ACCOUNT="${SERVER_NAME_LOWER}"
EOF
  chmod 600 "${OUTPUT_PATH}/config/keychain_manifest.conf"
  add_to_manifest "config/keychain_manifest.conf" "REQUIRED"
  echo "✅ Keychain manifest created"
}

# Set up operator account credentials using 1Password
set_section "Setting up operator account credentials"

# Initialize external keychain for credential storage
init_external_keychain

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

# Retrieve the operator password and store in external keychain
echo "Retrieving operator password from 1Password..."
OPERATOR_PASSWORD=$(op read "op://${ONEPASSWORD_VAULT}/${ONEPASSWORD_OPERATOR_ITEM}/password")
store_external_keychain_credential \
  "operator-${SERVER_NAME_LOWER}" \
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

  # Store TimeMachine credentials in external keychain (username:password format)
  store_external_keychain_credential \
    "timemachine-${SERVER_NAME_LOWER}" \
    "${SERVER_NAME_LOWER}" \
    "${TM_USERNAME}:${TM_PASSWORD}" \
    "Mac Server Setup - TimeMachine Credentials"

  # Create basic URL config file (non-sensitive)
  cat >"${OUTPUT_PATH}/config/timemachine.conf" <<EOF
TM_URL="${TM_URL}"
EOF
  chmod 644 "${OUTPUT_PATH}/config/timemachine.conf"
  add_to_manifest "config/timemachine.conf" "REQUIRED"

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

  # Store Plex NAS credentials in external keychain (username:password format)
  store_external_keychain_credential \
    "plex-nas-${SERVER_NAME_LOWER}" \
    "${SERVER_NAME_LOWER}" \
    "${PLEX_NAS_USERNAME}:${PLEX_NAS_PASSWORD}" \
    "Mac Server Setup - Plex NAS Credentials"

  # Create basic hostname config file (non-sensitive)
  cat >"${OUTPUT_PATH}/app-setup/config/plex_nas.conf" <<EOF
PLEX_NAS_HOSTNAME="${PLEX_NAS_HOSTNAME}"
EOF
  chmod 644 "${OUTPUT_PATH}/app-setup/config/plex_nas.conf"
  add_to_manifest "app-setup/config/plex_nas.conf" "REQUIRED"

  # Clear credentials from memory
  unset PLEX_NAS_USERNAME PLEX_NAS_PASSWORD
  echo "✅ Plex NAS credentials stored in Keychain"
fi

# Set up OpenSubtitles credentials using 1Password
echo "Setting up OpenSubtitles credentials..."

# Check if OpenSubtitles credentials exist in 1Password
if ! op item get "${OP_OPENSUBTITLES_ENTRY}" --vault "${ONEPASSWORD_VAULT}" >/dev/null 2>&1; then
  echo "⚠️ OpenSubtitles credentials not found in 1Password"
  echo "Please create '${OP_OPENSUBTITLES_ENTRY}' entry manually"
  echo "Skipping OpenSubtitles credential setup"
else
  echo "✅ Found OpenSubtitles credentials in 1Password"

  # Retrieve OpenSubtitles details from 1Password
  echo "Retrieving OpenSubtitles details from 1Password..."
  OPENSUBTITLES_USERNAME=$(op item get "${OP_OPENSUBTITLES_ENTRY}" --vault "${ONEPASSWORD_VAULT}" --fields username)
  OPENSUBTITLES_PASSWORD=$(op read "op://${ONEPASSWORD_VAULT}/${OP_OPENSUBTITLES_ENTRY}/password")

  # Store OpenSubtitles credentials in external keychain (username:password format)
  store_external_keychain_credential \
    "opensubtitles-${SERVER_NAME_LOWER}" \
    "${SERVER_NAME_LOWER}" \
    "${OPENSUBTITLES_USERNAME}:${OPENSUBTITLES_PASSWORD}" \
    "Mac Server Setup - OpenSubtitles Credentials"

  # Clear credentials from memory
  unset OPENSUBTITLES_USERNAME OPENSUBTITLES_PASSWORD
  echo "✅ OpenSubtitles credentials stored in Keychain"
fi

# Retrieve and cache Plex authentication token
if op item get "${ONEPASSWORD_PLEX_ITEM}" --vault "${ONEPASSWORD_VAULT}" >/dev/null 2>&1; then
  echo "✅ Found Plex credentials in 1Password"

  # Retrieve Plex credentials from 1Password
  echo "Retrieving Plex authentication token..."
  PLEX_USERNAME=$(op item get "${ONEPASSWORD_PLEX_ITEM}" --vault "${ONEPASSWORD_VAULT}" --fields username)
  PLEX_PASSWORD=$(op read "op://${ONEPASSWORD_VAULT}/${ONEPASSWORD_PLEX_ITEM}/password")

  # Check if TOTP is available and append it to password
  PLEX_TOTP=$(op item get "${ONEPASSWORD_PLEX_ITEM}" --vault "${ONEPASSWORD_VAULT}" --otp 2>/dev/null || echo "")
  if [[ -n "${PLEX_TOTP}" ]]; then
    echo "   Using TOTP for 2FA authentication"
    PLEX_AUTH_PASSWORD="${PLEX_PASSWORD}${PLEX_TOTP}"
  else
    PLEX_AUTH_PASSWORD="${PLEX_PASSWORD}"
  fi

  # Get authentication token from plex.tv
  PLEX_AUTH_RESPONSE=$(curl -s -X POST 'https://plex.tv/users/sign_in.json' \
    -H 'X-Plex-Client-Identifier: mac-server-setup' \
    -H 'X-Plex-Product: mac-server-setup' \
    -H 'X-Plex-Version: 1.0' \
    --data-urlencode "user[login]=${PLEX_USERNAME}" \
    --data-urlencode "user[password]=${PLEX_AUTH_PASSWORD}") || {
    echo "⚠️  Failed to authenticate with Plex - token will need manual setup"
    PLEX_TOKEN=""
  }

  # Extract the authentication token using jq
  if [[ -n "${PLEX_AUTH_RESPONSE:-}" ]]; then
    PLEX_TOKEN=$(echo "${PLEX_AUTH_RESPONSE}" | jq -r '.user.authToken' 2>/dev/null || echo "")
    if [[ "${PLEX_TOKEN}" == "null" || -z "${PLEX_TOKEN}" ]]; then
      echo "⚠️  Failed to get Plex authentication token - may need manual setup"
      PLEX_TOKEN=""
    fi
  fi

  # Store Plex token in external keychain if we got one
  if [[ -n "${PLEX_TOKEN}" ]]; then
    store_external_keychain_credential \
      "plex-token-${SERVER_NAME_LOWER}" \
      "${SERVER_NAME_LOWER}" \
      "${PLEX_TOKEN}" \
      "Mac Server Setup - Plex Authentication Token"
    echo "✅ Plex authentication token retrieved and stored in Keychain"
  fi

  # Clear sensitive credentials from memory
  unset PLEX_USERNAME PLEX_PASSWORD PLEX_TOTP PLEX_AUTH_PASSWORD PLEX_AUTH_RESPONSE PLEX_TOKEN
else
  echo "⚠️  Plex credentials not found in 1Password - token will need manual setup"
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

# Copy FileBot license file if configured
if [[ -n "${FILEBOT_LICENSE_FILE:-}" ]]; then
  if [[ -f "${FILEBOT_LICENSE_FILE}" ]]; then
    echo "Copying FileBot license file..."
    license_filename="$(basename "${FILEBOT_LICENSE_FILE}")"
    copy_with_manifest "${FILEBOT_LICENSE_FILE}" "app-setup/config/${license_filename}" "OPTIONAL"
    chmod 600 "${OUTPUT_PATH}/app-setup/config/${license_filename}"
    add_to_manifest "app-setup/config/${license_filename}" "OPTIONAL"
    echo "✅ FileBot license file copied to app-setup/config/${license_filename}"
  else
    collect_warning "FileBot license file not found at: ${FILEBOT_LICENSE_FILE}"
  fi
else
  echo "No FileBot license file configured - skipping FileBot license copy"
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
  add_to_manifest "config/apple_id_password.url" "OPTIONAL"
  echo "✅ Apple ID one-time password link saved to config/apple_id_password.url"
else
  echo "⚠️ No URL provided, skipping Apple ID password link creation"
fi

# Operator first-login script will be copied with all other server scripts below

# Copy from local script source directory
if [[ -d "${SCRIPT_SOURCE_DIR}" ]]; then
  set_section "Copying scripts from local source directory"

  # Copy main entry point script to root
  copy_with_manifest "${SCRIPT_SOURCE_DIR}/scripts/server/first-boot.sh" "first-boot.sh" "REQUIRED" || collect_warning "first-boot.sh not found in server directory"
  chmod +x "${OUTPUT_PATH}/first-boot.sh" 2>/dev/null

  # Copy all server scripts to scripts directory (excluding first-boot.sh which goes to root)
  echo "Copying all server scripts to deployment package..."
  for script in "${SCRIPT_SOURCE_DIR}/scripts/server/"*.sh; do
    script_name="$(basename "${script}")"
    # Skip first-boot.sh as it's handled separately
    if [[ "${script_name}" != "first-boot.sh" ]]; then
      if copy_with_manifest "${script}" "scripts/${script_name}" "REQUIRED"; then
        chmod +x "${OUTPUT_PATH}/scripts/${script_name}"
        echo "  ✅ ${script_name}"
      else
        echo "  ❌ Failed to copy ${script_name}"
      fi
    fi
  done

  # Copy template scripts to app-setup/templates
  copy_with_manifest "${SCRIPT_SOURCE_DIR}/app-setup/app-setup-templates/mount-nas-media.sh" "app-setup/templates/mount-nas-media.sh" "REQUIRED" || echo "Warning: mount-nas-media.sh not found in app-setup-templates directory"
  copy_with_manifest "${SCRIPT_SOURCE_DIR}/app-setup/app-setup-templates/start-plex.sh" "app-setup/templates/start-plex.sh" "OPTIONAL" || echo "Warning: start-plex.sh not found in app-setup-templates directory"
  copy_with_manifest "${SCRIPT_SOURCE_DIR}/app-setup/app-setup-templates/start-rclone.sh" "app-setup/templates/start-rclone.sh" "REQUIRED" || echo "Warning: start-rclone.sh not found in app-setup-templates directory"

  # Copy app setup scripts to app-setup directory
  echo "Copying app setup scripts..."
  for app_script in "${SCRIPT_SOURCE_DIR}/app-setup/"*.sh; do
    if [[ -f "${app_script}" ]]; then
      script_name="$(basename "${app_script}")"
      copy_with_manifest "${app_script}" "app-setup/${script_name}" "REQUIRED"
      chmod +x "${OUTPUT_PATH}/app-setup/${script_name}"
      echo "  ✅ ${script_name}"
    fi
  done

  # Copy system configuration files
  copy_with_manifest "${SCRIPT_SOURCE_DIR}/config/formulae.txt" "config/formulae.txt" "REQUIRED" || echo "Warning: formulae.txt not found in source directory"
  copy_with_manifest "${SCRIPT_SOURCE_DIR}/config/casks.txt" "config/casks.txt" "REQUIRED" || echo "Warning: casks.txt not found in source directory"
  copy_with_manifest "${SCRIPT_SOURCE_DIR}/config/logrotate.conf" "config/logrotate.conf" "OPTIONAL" || echo "Warning: logrotate.conf not found in source directory"

  # Copy configuration file if it exists
  if [[ -f "${CONFIG_FILE}" ]]; then
    copy_with_manifest "${CONFIG_FILE}" "config/config.conf" "REQUIRED"
    echo "Configuration file copied to setup package"
  fi

  # Copy terminal profile files if specified in configuration
  if [[ -n "${TERMINAL_PROFILE_FILE:-}" ]]; then
    terminal_src="${CONFIG_DIR}/${TERMINAL_PROFILE_FILE}"
    if [[ -f "${terminal_src}" ]]; then
      copy_with_manifest "${terminal_src}" "config/${TERMINAL_PROFILE_FILE}" "OPTIONAL"
      echo "Terminal profile copied to deployment package: ${TERMINAL_PROFILE_FILE}"
    else
      echo "Warning: Terminal profile file not found: ${terminal_src}"
    fi
  fi

  # Export iTerm2 preferences if requested
  if [[ "${USE_ITERM2:-false}" == "true" ]]; then
    if command -v it2check >/dev/null 2>&1; then
      echo "Exporting iTerm2 preferences..."
      if defaults export com.googlecode.iterm2 "${OUTPUT_PATH}/config/iterm2.plist"; then
        add_to_manifest "config/iterm2.plist" "OPTIONAL"
        echo "iTerm2 preferences exported to deployment package"
      else
        echo "Warning: Failed to export iTerm2 preferences"
      fi
    else
      echo "Warning: USE_ITERM2 is enabled but iTerm2 is not installed (it2check not found)"
    fi
  fi

  echo "Scripts copied from local source directory"
else
  collect_error "No script source found. Please provide a local script source directory."
  exit 1
fi

# Copy Bash configuration
set_section "Copying Bash Configuration"

# Define source and destination paths for bash config
BASH_CONFIG_SOURCE="${HOME}/.config/bash"
BASH_CONFIG_DEST="${OUTPUT_PATH}/bash"

# Copy bash configuration directory with manifest tracking
copy_dir_with_manifest "${BASH_CONFIG_SOURCE}" "bash" "OPTIONAL" ".git|.claude|backups"

# Clean up development-specific files from bash config and manifest if they were copied
if [[ -d "${BASH_CONFIG_DEST}" ]]; then
  # Remove development-specific files that shouldn't be deployed
  for ITEM in .DS_Store .gitignore .shellcheckrc .yamllint secrets.sh "*.bak"; do
    rm -rf "${BASH_CONFIG_DEST:?}/${ITEM:?}" 2>/dev/null || true
    remove_from_manifest "bash/${ITEM}" "OPTIONAL"
  done

  # Set appropriate permissions
  chmod -R 644 "${BASH_CONFIG_DEST}/"*.sh 2>/dev/null || true
  chmod 644 "${BASH_CONFIG_DEST}/.bash_profile" 2>/dev/null || true
fi

# Copy README with variable substitution
if [[ -f "${SCRIPT_SOURCE_DIR}/docs/setup/firstboot-README.md" ]]; then
  echo "Processing README file..."
  sed "s/\${SERVER_NAME_LOWER}/${SERVER_NAME_LOWER}/g" \
    "${SCRIPT_SOURCE_DIR}/docs/setup/firstboot-README.md" >"${OUTPUT_PATH}/README.md"
  add_to_manifest "README.md" "REQUIRED"
  echo "✅ README creation"
else
  echo "⚠️ firstboot-README.md not found in source directory"
  add_to_manifest "README.md" "MISSING"
fi

echo "Setting file permissions..."
chmod 755 "${OUTPUT_PATH}/first-boot.sh" 2>/dev/null || true
chmod -R 755 "${OUTPUT_PATH}/scripts"
chmod -R 755 "${OUTPUT_PATH}/app-setup"
chmod 600 "${OUTPUT_PATH}/config/"* 2>/dev/null || true
chmod 600 "${OUTPUT_PATH}/app-setup/config/"* 2>/dev/null || true

# Create Keychain manifest for server-side credential access
create_keychain_manifest

# Finalize external keychain and add to airdrop package
finalize_external_keychain

# Show collected errors and warnings
show_collected_issues

echo ""
echo "====== Setup Files Preparation Complete ======"
echo "The setup files at ${OUTPUT_PATH} are now ready for AirDrop."
echo "AirDrop this entire folder to your Mac Mini after completing the macOS setup wizard"
echo "and run ./first-boot.sh from the transferred directory root."

open "${OUTPUT_PATH}"

exit 0
