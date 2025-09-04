#!/usr/bin/env bash

#
# rclone-airdrop-prep.sh - Dropbox/rclone configuration for Mac Mini server setup
#
# This script handles rclone installation, OAuth authentication, and configuration
# transfer for Dropbox synchronization on the server.
#
# Called by: airdrop-prep.sh
# Requires: DROPBOX_SYNC_FOLDER, DROPBOX_LOCAL_PATH, OUTPUT_PATH, SERVER_NAME_LOWER
#

# Exit on error
set -euo pipefail

# Check required variables are set
if [[ -z "${OUTPUT_PATH:-}" ]]; then
  echo "Error: OUTPUT_PATH not set - this script must be called from airdrop-prep.sh"
  exit 1
fi

if [[ -z "${SERVER_NAME_LOWER:-}" ]]; then
  echo "Error: SERVER_NAME_LOWER not set - this script must be called from airdrop-prep.sh"
  exit 1
fi

# Set up Dropbox credentials and configuration using rclone
echo ""
echo "====== Dropbox Configuration Setup ======"

# Check if Dropbox configuration is requested
if [[ -n "${DROPBOX_SYNC_FOLDER:-}" ]]; then
  echo "Dropbox sync requested for folder: ${DROPBOX_SYNC_FOLDER}"

  # Check if rclone is already installed
  RCLONE_WAS_INSTALLED=false
  if command -v rclone >/dev/null 2>&1; then
    echo "✅ rclone is already installed"
    RCLONE_WAS_INSTALLED=true
  else
    echo "Installing rclone temporarily for Dropbox configuration..."
    brew install rclone
    echo "✅ rclone installed"
  fi

  # Set up rclone configuration
  echo "Setting up rclone Dropbox OAuth configuration..."
  echo "You will need to authenticate with Dropbox in your browser."
  echo "This creates an OAuth token that will be transferred to the server."
  echo ""

  # Create rclone config for dropbox remote named after server
  RCLONE_REMOTE_NAME="${SERVER_NAME_LOWER}_dropbox"

  echo "Creating rclone remote: ${RCLONE_REMOTE_NAME}"
  echo "This will open your browser for Dropbox OAuth authentication."
  echo ""
  read -r -p "Press Enter to start Dropbox configuration..."

  # Create the remote configuration (handles OAuth automatically)
  echo "Opening browser for Dropbox authorization..."
  echo "Complete the OAuth process in your browser, then return here."
  if rclone config create "${RCLONE_REMOTE_NAME}" dropbox; then
    echo "✅ rclone Dropbox configuration completed"

    # Copy the rclone config file to the setup package
    RCLONE_CONFIG_PATH="${HOME}/.config/rclone/rclone.conf"

    # Wait for rclone to write the config file (with timeout)
    echo "Waiting for rclone configuration file to be created..."
    config_wait_timeout=10
    config_wait_elapsed=0

    while [[ ${config_wait_elapsed} -lt ${config_wait_timeout} ]]; do
      if [[ -f "${RCLONE_CONFIG_PATH}" ]]; then
        echo "✅ rclone configuration file found"
        break
      fi
      sleep 1
      ((config_wait_elapsed += 1))
    done

    if [[ -f "${RCLONE_CONFIG_PATH}" ]]; then
      if cp "${RCLONE_CONFIG_PATH}" "${OUTPUT_PATH}/app-setup/config/rclone.conf"; then
        chmod 600 "${OUTPUT_PATH}/app-setup/config/rclone.conf"
        echo "✅ rclone configuration saved for transfer"
      else
        echo "❌ Failed to copy rclone configuration file"
        exit 1
      fi
    else
      echo "❌ rclone configuration file not found at ${RCLONE_CONFIG_PATH} after ${config_wait_timeout}s"
      echo "Config directory contents:"
      ls -la "${HOME}/.config/rclone/" 2>/dev/null || echo "Directory does not exist"
      exit 1
    fi

    # Create Dropbox sync configuration file
    cat >"${OUTPUT_PATH}/app-setup/config/dropbox_sync.conf" <<EOF
DROPBOX_SYNC_FOLDER="${DROPBOX_SYNC_FOLDER}"
DROPBOX_LOCAL_PATH="${DROPBOX_LOCAL_PATH:-\$HOME/.local/sync/dropbox}"
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME}"
EOF
    chmod 600 "${OUTPUT_PATH}/app-setup/config/dropbox_sync.conf"
    echo "✅ Dropbox sync configuration saved for transfer"

    # Test the configuration (list only, no sync)
    echo "Testing Dropbox connection..."
    if rclone lsd "${RCLONE_REMOTE_NAME}:" --max-depth 1 >/dev/null 2>&1; then
      echo "✅ Dropbox connection test successful"
    else
      echo "⚠️ Dropbox connection test failed - configuration may need adjustment"
    fi
  else
    echo "❌ Failed to create rclone remote configuration"
  fi

  # Clean up rclone if we installed it
  if [[ "${RCLONE_WAS_INSTALLED}" == "false" ]]; then
    echo ""
    echo "Cleaning up rclone installation..."
    brew uninstall rclone
    echo "✅ rclone removed (was not previously installed)"
  fi
else
  echo "No Dropbox sync folder specified in configuration - skipping Dropbox setup"
  echo "To enable Dropbox sync, set DROPBOX_SYNC_FOLDER in your config.conf"
fi

exit 0
