#!/bin/bash
#
# airdrop-prep.sh - Script to prepare a directory with necessary files for Mac Mini M2 'TILSIT' server setup
#
# This script prepares a directory with all the necessary scripts and files
# for setting up the Mac Mini M2 server. After running, AirDrop the entire directory
# to your new Mac Mini.
#
# Usage: ./airdrop-prep.sh [output_path] [script_path]
#	output_path: Path where the files will be created (default: ~/tilsit-setup)
#
# Author: Claude
# Version: 1.2
# Created: 2025-05-13

# Exit on error
set -e

# Configuration
OUTPUT_PATH="${1:-$HOME/tilsit-setup}"
GITHUB_REPO="https://github.com/yourusername/tilsit-setup.git"	# Replace with your actual repository
SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"  # Adjust to your SSH key path
SCRIPT_SOURCE_DIR="${2:-.}"  # Directory containing source scripts (default is current dir)

# Check if output directory exists, create if not
if [ ! -d "$OUTPUT_PATH" ]; then
  echo "Creating output directory: $OUTPUT_PATH"
  mkdir -p "$OUTPUT_PATH"
fi

echo "====== Preparing TILSIT Server Setup Files for AirDrop ======"
echo "Output path: $OUTPUT_PATH"
echo "Date: $(date)"

# Create directory structure
echo "Creating directory structure..."
mkdir -p "$OUTPUT_PATH/ssh_keys"
mkdir -p "$OUTPUT_PATH/scripts"
mkdir -p "$OUTPUT_PATH/scripts/app-setup"
mkdir -p "$OUTPUT_PATH/lists"
mkdir -p "$OUTPUT_PATH/pam.d"
mkdir -p "$OUTPUT_PATH/wifi"

# Copy SSH keys
if [ -f "$SSH_KEY_PATH" ]; then
  echo "Copying SSH public key..."
  cp "$SSH_KEY_PATH" "$OUTPUT_PATH/ssh_keys/authorized_keys"

  # Create operator keys (same as admin for now)
  cp "$SSH_KEY_PATH" "$OUTPUT_PATH/ssh_keys/operator_authorized_keys"
else
  echo "Warning: SSH public key not found at $SSH_KEY_PATH"
  echo "Please generate SSH keys or specify the correct path"
fi

# Check for TouchID sudo file and copy if exists
if [ -f "/etc/pam.d/sudo_local" ]; then
  echo "Copying TouchID sudo file..."
  cp "/etc/pam.d/sudo_local" "$OUTPUT_PATH/pam.d/"
  chmod +w "$OUTPUT_PATH/pam.d/sudo_local"
else
  echo "Warning: TouchID sudo file not found at /etc/pam.d/sudo_local"
  echo "TouchID sudo will not be configured on the server"
fi

# Get current WiFi network info
echo "Getting current WiFi network information..."
CURRENT_SSID=$(system_profiler SPAirPortDataType | awk '/Current Network/ {getline;$1=$1;print $0 | "tr -d \":\"";exit}')

if [ -n "$CURRENT_SSID" ]; then
  echo "Current WiFi network SSID: $CURRENT_SSID"

  echo "Retrieving WiFi password..."
  echo "You'll be prompted for your administrator password to access the keychain."
  WIFI_PASSWORD=$(security find-generic-password -a "$CURRENT_SSID" -w "/Library/Keychains/System.keychain")

  if [ -n "$WIFI_PASSWORD" ]; then
	echo "WiFi password retrieved successfully."

	# Save WiFi information securely
	cat > "$OUTPUT_PATH/wifi/network.conf" << EOF
WIFI_SSID="$CURRENT_SSID"
WIFI_PASSWORD="$WIFI_PASSWORD"
EOF
	chmod 600 "$OUTPUT_PATH/wifi/network.conf"
	echo "WiFi network configuration saved to wifi/network.conf"
  else
	echo "Error: Could not retrieve WiFi password."
	echo "WiFi network configuration will not be automated."
  fi
else
  echo "Warning: Could not detect current WiFi network."
  echo "WiFi network configuration will not be automated."
fi

# Option 1: Clone from GitHub repository if available
if [[ -n "$GITHUB_REPO" && "$GITHUB_REPO" != "https://github.com/yourusername/tilsit-setup.git" ]]; then
  echo "Cloning setup scripts from GitHub repository..."

  # Create temporary directory
  TMP_DIR=$(mktemp -d)

  # Clone repository
  git clone "$GITHUB_REPO" "$TMP_DIR"

  # Copy scripts to output directory
  cp "$TMP_DIR/first-boot.sh" "$OUTPUT_PATH/scripts/"
  cp "$TMP_DIR/second-boot.sh" "$OUTPUT_PATH/scripts/"
  cp "$TMP_DIR/app-setup/"*.sh "$OUTPUT_PATH/scripts/app-setup/"
  cp "$TMP_DIR/formulae.txt" "$OUTPUT_PATH/lists/"
  cp "$TMP_DIR/casks.txt" "$OUTPUT_PATH/lists/"

  # Clean up
  rm -rf "$TMP_DIR"

  echo "Scripts copied from GitHub repository"
# Option 2: Copy from local script source directory
elif [ -d "$SCRIPT_SOURCE_DIR" ]; then
  echo "Copying scripts from local source directory..."

  # Copy scripts
  cp "$SCRIPT_SOURCE_DIR/first-boot.sh" "$OUTPUT_PATH/scripts/" 2>/dev/null || echo "Warning: first-boot.sh not found in source directory"
  cp "$SCRIPT_SOURCE_DIR/second-boot.sh" "$OUTPUT_PATH/scripts/" 2>/dev/null || echo "Warning: second-boot.sh not found in source directory"
  cp "$SCRIPT_SOURCE_DIR/app-setup/"*.sh "$OUTPUT_PATH/scripts/app-setup/" 2>/dev/null || echo "Warning: No app setup scripts found in source directory"
  cp "$SCRIPT_SOURCE_DIR/formulae.txt" "$OUTPUT_PATH/lists/" 2>/dev/null || echo "Warning: formulae.txt not found in source directory"
  cp "$SCRIPT_SOURCE_DIR/casks.txt" "$OUTPUT_PATH/lists/" 2>/dev/null || echo "Warning: casks.txt not found in source directory"

  echo "Scripts copied from local source directory"
else
  echo "Error: No script source found. Please specify a GitHub repository or provide a local script source directory."
  exit 1
fi

# Create a README file
echo "Creating README file..."
cat > "$OUTPUT_PATH/README.md" << 'EOF'
# TILSIT Server Setup Files

This directory contains all the necessary files for setting up the Mac Mini M2 'TILSIT' server.

## Contents

- `ssh_keys/`: SSH public keys for secure remote access
- `scripts/`: Setup scripts for the server
- `lists/`: Homebrew formulae and casks lists
- `pam.d/`: TouchID sudo configuration
- `wifi/`: WiFi network configuration

## Setup Instructions

1. Complete the macOS setup wizard on the Mac Mini
2. AirDrop this entire folder to the Mac Mini (it will be placed in Downloads)
3. Move the folder to your home directory:
   ```bash
   mv ~/Downloads/tilsit-setup ~/
   ```
4. Open Terminal and run:
   ```bash
   cd ~/tilsit-setup/scripts
   chmod +x first-boot.sh
   ./first-boot.sh
   ```
5. Follow the on-screen instructions
6. After reboot, the second-boot script will run automatically

For detailed instructions, refer to the complete runbook.

## Notes

- The operator account password will be saved to `~/Documents/operator_password.txt`
- After setup, you can access the server via SSH using the admin or operator account
- TouchID sudo will be enabled if the configuration file was available during preparation
- WiFi will be configured automatically using the saved network information

Created: $(date)
EOF

echo "Setting file permissions..."
chmod -R 755 "$OUTPUT_PATH/scripts"
chmod 600 "$OUTPUT_PATH/wifi/network.conf" 2>/dev/null || true

echo "====== Setup Files Preparation Complete ======"
echo "The setup files at $OUTPUT_PATH are now ready for AirDrop."
echo "AirDrop this entire folder to your Mac Mini after completing the macOS setup wizard"
echo "and run the first-boot.sh script from the transferred directory."

open "$OUTPUT_PATH"

exit 0
