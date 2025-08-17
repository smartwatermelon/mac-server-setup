#!/usr/bin/env bash
#
# create-touchid-sudo.sh - Script to create TouchID sudo configuration file on Mac
#
# This script creates the sudo_local file that enables TouchID authentication
# for sudo commands on macOS. Run this on your development Mac before using
# airdrop-prep.sh if you don't already have the file.
#
# Usage: ./create-touchid-sudo.sh
#
# Author: Claude
# Version: 1.0
# Created: 2025-05-16

# Exit on error
set -euo pipefail

# Target file
SUDO_LOCAL_FILE="/etc/pam.d/sudo_local"

# Check if file already exists
if [[ -f "${SUDO_LOCAL_FILE}" ]]; then
  echo "TouchID sudo file already exists at ${SUDO_LOCAL_FILE}"
  echo "Contents:"
  cat "${SUDO_LOCAL_FILE}"
  exit 0
fi

echo "Creating TouchID sudo configuration file at ${SUDO_LOCAL_FILE}"

# Create sudo_local file with TouchID configuration
sudo tee "${SUDO_LOCAL_FILE}" >/dev/null <<'EOF'
# sudo_local: PAM configuration for enabling TouchID for sudo
#
# This file enables the use of TouchID as an authentication method for sudo
# commands on macOS. It is used in addition to the standard sudo configuration.
#
# Format: auth sufficient pam_tid.so

# Allow TouchID authentication for sudo
auth       sufficient     pam_tid.so
EOF

sudo chmod 644 "${SUDO_LOCAL_FILE}"

echo "✅ TouchID sudo configuration created successfully"
echo "You can now use TouchID for sudo authentication"
echo "This file will be copied to your Mac Mini during setup"

exit 0
