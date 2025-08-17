#!/usr/bin/env bash
#
# plex-setup.sh - Native Plex Media Server setup script for Mac Mini M2 server
#
# This script sets up Plex Media Server natively on macOS with:
# - SMB mount to NAS for media storage (retrieved from config.conf)
# - Native Plex installation via official installer
# - Configuration migration from existing Plex server
# - Auto-start configuration
#
# Usage: ./plex-setup.sh [--force] [--skip-migration] [--skip-mount] [--server-name NAME] [--migrate-from HOST]
#   --force: Skip all confirmation prompts
#   --skip-migration: Skip Plex config migration
#   --skip-mount: Skip SMB mount setup
#   --server-name: Set Plex server name (default: hostname)
#   --migrate-from: Source hostname for Plex migration (e.g., old-server.local)
#   Note: --skip-migration and --migrate-from are mutually exclusive
#
# Expected Plex config files location:
#   ~/plex-migration/
#     ├── Plex Media Server/          # Main config directory from old server
#     └── com.plexapp.plexmediaserver.plist   # macOS preferences file
#
# Author: Claude
# Version: 3.0 (Native)
# Created: 2025-08-17

# Exit on error
set -euo pipefail

# Load server configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
  NAS_USERNAME="${NAS_USERNAME:-plex}"
  NAS_HOSTNAME="${NAS_HOSTNAME:-nas.local}"
  NAS_SHARE_NAME="${NAS_SHARE_NAME:-Media}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Derive configuration variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Plex configuration
PLEX_MEDIA_MOUNT="/Volumes/DSMedia"
PLEX_SERVER_NAME="${PLEX_SERVER_NAME_OVERRIDE:-${HOSTNAME} Plex}"

# Migration settings
PLEX_OLD_CONFIG="${HOME}/plex-migration/Plex Media Server"
PLEX_NEW_CONFIG="/Users/Shared/PlexMediaServer"

# Parse command line arguments
FORCE=false
SKIP_MIGRATION=false
SKIP_MOUNT=false
MIGRATE_FROM=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --skip-migration)
      SKIP_MIGRATION=true
      shift
      ;;
    --skip-mount)
      SKIP_MOUNT=true
      shift
      ;;
    --server-name)
      PLEX_SERVER_NAME="$2"
      shift 2
      ;;
    --migrate-from)
      MIGRATE_FROM="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--force] [--skip-migration] [--skip-mount] [--server-name NAME] [--migrate-from HOST]"
      exit 1
      ;;
  esac
done

# Validate conflicting options
if [[ "${SKIP_MIGRATION}" == "true" && -n "${MIGRATE_FROM}" ]]; then
  echo "Error: --skip-migration and --migrate-from cannot be used together"
  exit 1
fi

# Set up logging
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-apps.log"
mkdir -p "${LOG_DIR}"

# Logging functions
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

show_log() {
  echo "$*" | tee -a "${LOG_FILE}"
}

check_success() {
  if [[ $? -eq 0 ]]; then
    log "✅ $1"
  else
    log "❌ $1 failed"
    exit 1
  fi
}

section() {
  echo ""
  show_log "=================================================================================="
  show_log "$1"
  show_log "=================================================================================="
  echo ""
}

confirm() {
  if [[ "${FORCE}" == "true" ]]; then
    return 0
  fi

  local prompt="$1"
  local default="${2:-y}"

  if [[ "${default}" == "y" ]]; then
    read -rp "${prompt} (Y/n): " response
    response=${response:-y}
  else
    read -rp "${prompt} (y/N): " response
    response=${response:-n}
  fi

  case "${response}" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# SMB Mount Setup (autofs-based)
setup_smb_mount() {
  section "Setting Up SMB Mount for Media Storage"

  # Check if we have 1Password CLI access
  if ! command -v op &>/dev/null; then
    log "❌ 1Password CLI not found. Install with: brew install --cask 1password-cli"
    exit 1
  fi

  # Test 1Password access
  if ! op whoami &>/dev/null; then
    log "❌ Not signed in to 1Password CLI. Run: op signin"
    exit 1
  fi

  # Get NAS credentials from 1Password
  log "Retrieving NAS credentials from 1Password..."
  PLEX_NAS_USERNAME=""
  PLEX_NAS_PASSWORD=""

  PLEX_NAS_USERNAME=$(op item get "${ONEPASSWORD_NAS_ITEM:-plex-nas}" --fields username 2>/dev/null || echo "")
  PLEX_NAS_PASSWORD=$(op item get "${ONEPASSWORD_NAS_ITEM:-plex-nas}" --fields password 2>/dev/null || echo "")

  if [[ -z "${PLEX_NAS_USERNAME}" || -z "${PLEX_NAS_PASSWORD}" ]]; then
    log "❌ Could not retrieve NAS credentials from 1Password item: ${ONEPASSWORD_NAS_ITEM:-plex-nas}"
    exit 1
  fi

  # Configure autofs for automatic mounting
  log "Configuring autofs for automatic SMB mounting"

  local auto_master="/etc/auto_master"
  local auto_smb="/etc/auto_smb"
  local autofs_line="/Volumes  auto_smb  -nobrowse,nosuid"

  # Add autofs line to auto_master if not present
  if ! grep -q "auto_smb" "${auto_master}"; then
    log "Adding autofs configuration to ${auto_master}"
    echo "${autofs_line}" | sudo -p "Enter your '${USER}' password to configure autofs: " tee -a "${auto_master}" >/dev/null
    check_success "autofs master configuration"
  fi

  # Create or update auto_smb file
  local mount_hostname="${NAS_HOSTNAME}"
  local autofs_mount_line="DSMedia  -fstype=smbfs,soft ://${PLEX_NAS_USERNAME}:${PLEX_NAS_PASSWORD}@${mount_hostname}/${NAS_SHARE_NAME}"

  if [[ -f "${auto_smb}" ]]; then
    if ! grep -q "DSMedia" "${auto_smb}"; then
      log "Adding DSMedia mount to existing ${auto_smb}"
      echo "${autofs_mount_line}" | sudo -p "Enter your '${USER}' password to update autofs SMB config: " tee -a "${auto_smb}" >/dev/null
      check_success "autofs SMB mount addition"
    fi
  else
    log "Creating ${auto_smb} with DSMedia mount"
    echo "${autofs_mount_line}" | sudo -p "Enter your '${USER}' password to create autofs SMB config: " tee "${auto_smb}" >/dev/null
    check_success "autofs SMB config creation"
  fi

  # Set proper permissions
  sudo -p "Enter your '${USER}' password to set autofs config permissions: " chmod 644 "${auto_smb}"
  check_success "autofs permissions"

  # Restart autofs
  log "Restarting autofs service"
  if sudo -p "Enter your '${USER}' password to restart autofs service: " automount -cv >/dev/null 2>&1; then
    check_success "autofs restart"
    log "✅ SMB mount configured successfully"
    log "The NAS will automatically mount when accessed: ${PLEX_MEDIA_MOUNT}"
  else
    log "❌ Failed to restart autofs service"
    exit 1
  fi
}

# Download and install Plex Media Server
install_plex() {
  section "Installing Plex Media Server"

  # Check if Plex is already installed
  if [[ -d "/Applications/Plex Media Server.app" ]]; then
    log "Plex Media Server is already installed at /Applications/Plex Media Server.app"
    log "✅ Using existing Plex installation"
    return 0
  fi

  # Check if it was installed via Homebrew cask
  if command -v brew &>/dev/null && brew list --cask plex-media-server &>/dev/null; then
    log "Plex Media Server is installed via Homebrew but not found in Applications"
    log "This may indicate a Homebrew installation issue"
  fi

  log "Downloading Plex Media Server for macOS..."

  # Create temporary directory for download
  TEMP_DIR=$(mktemp -d)
  PLEX_DMG="${TEMP_DIR}/PlexMediaServer.dmg"

  # Download latest Plex Media Server
  PLEX_DOWNLOAD_URL="https://downloads.plex.tv/plex-media-server-new/1.40.4.8679-424562606/macos/PlexMediaServer-1.40.4.8679-424562606-universal.dmg"

  log "Downloading from: ${PLEX_DOWNLOAD_URL}"
  if curl -L -o "${PLEX_DMG}" "${PLEX_DOWNLOAD_URL}"; then
    check_success "Plex Media Server download"
  else
    log "❌ Failed to download Plex Media Server"
    log "Please download manually from: https://www.plex.tv/media-server-downloads/"
    exit 1
  fi

  # Mount the DMG
  log "Mounting Plex installer..."
  MOUNT_POINT=$(hdiutil attach "${PLEX_DMG}" | grep "/Volumes/" | awk '{print $3}')

  if [[ -z "${MOUNT_POINT}" ]]; then
    log "❌ Failed to mount Plex installer DMG"
    exit 1
  fi

  # Install Plex
  log "Installing Plex Media Server..."
  if cp -R "${MOUNT_POINT}/Plex Media Server.app" "/Applications/"; then
    check_success "Plex Media Server installation"
  else
    log "❌ Failed to install Plex Media Server"
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
    exit 1
  fi

  # Clean up
  hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
  rm -rf "${TEMP_DIR}"

  log "✅ Plex Media Server installed successfully"
}

# Create shared Plex configuration directory
setup_shared_config() {
  section "Setting Up Shared Plex Configuration Directory"

  log "Creating shared Plex configuration directory at ${PLEX_NEW_CONFIG}"

  # Create the shared directory
  sudo -p "Enter your '${USER}' password to create shared Plex directory: " mkdir -p "${PLEX_NEW_CONFIG}"
  check_success "Shared Plex directory creation"

  # Set ownership to admin:staff and permissions for both admin and operator access
  sudo -p "Enter your '${USER}' password to set Plex directory ownership: " chown "${USER}:staff" "${PLEX_NEW_CONFIG}"
  check_success "Plex directory ownership"

  # Set permissions: owner and group can read/write, others can read
  sudo -p "Enter your '${USER}' password to set Plex directory permissions: " chmod 775 "${PLEX_NEW_CONFIG}"
  check_success "Plex directory permissions"

  # Add operator to staff group if not already a member
  log "Ensuring operator user ${OPERATOR_USERNAME} is in staff group..."
  if ! groups "${OPERATOR_USERNAME}" | grep -q "staff"; then
    sudo -p "Enter your '${USER}' password to add operator to staff group: " dseditgroup -o edit -a "${OPERATOR_USERNAME}" -t user staff
    check_success "Operator staff group membership"
  else
    log "✅ Operator ${OPERATOR_USERNAME} is already in staff group"
  fi

  log "✅ Shared Plex configuration directory ready"
}

# Migrate existing Plex configuration
migrate_plex_config() {
  section "Plex Configuration Migration"

  if [[ "${SKIP_MIGRATION}" == "true" ]]; then
    log "Skipping Plex configuration migration (--skip-migration specified)"
    return 0
  fi

  if [[ ! -d "${PLEX_OLD_CONFIG}" ]]; then
    log "No existing Plex configuration found at ${PLEX_OLD_CONFIG}"
    log "Plex will start with fresh configuration"
    return 0
  fi

  if confirm "Apply migrated Plex configuration?" "y"; then
    log "Stopping Plex Media Server if running..."
    pkill -f "Plex Media Server" 2>/dev/null || true
    sleep 3

    log "Backing up any existing configuration..."
    if [[ -d "${PLEX_NEW_CONFIG}/Plex Media Server" ]]; then
      backup_timestamp=$(date +%Y%m%d_%H%M%S)
      sudo -p "Enter your '${USER}' password to backup existing Plex config: " mv "${PLEX_NEW_CONFIG}/Plex Media Server" "${PLEX_NEW_CONFIG}/Plex Media Server.backup.${backup_timestamp}"
    fi

    log "Copying migrated configuration to shared directory..."
    sudo -p "Enter your '${USER}' password to copy migrated Plex config: " cp -R "${PLEX_OLD_CONFIG}" "${PLEX_NEW_CONFIG}/"
    check_success "Plex configuration migration"

    # Ensure proper permissions on migrated files
    log "Setting permissions on migrated configuration..."
    sudo -p "Enter your '${USER}' password to set migrated config ownership: " chown -R "${USER}:staff" "${PLEX_NEW_CONFIG}/Plex Media Server"
    sudo -p "Enter your '${USER}' password to set migrated config permissions: " chmod -R 775 "${PLEX_NEW_CONFIG}/Plex Media Server"
    check_success "Migrated configuration permissions"

    log "✅ Plex configuration migrated successfully"
  else
    log "Skipping configuration migration"
  fi
}

# Configure Plex for auto-start
configure_plex_autostart() {
  section "Configuring Plex Auto-Start"

  # Create a simple LaunchAgent for the operator user
  OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
  LAUNCH_AGENTS_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
  PLIST_FILE="${LAUNCH_AGENTS_DIR}/com.plexapp.plexmediaserver.plist"

  log "Creating LaunchAgent for Plex auto-start..."
  sudo -u "${OPERATOR_USERNAME}" mkdir -p "${LAUNCH_AGENTS_DIR}"

  cat <<EOF | sudo -u "${OPERATOR_USERNAME}" tee "${PLIST_FILE}" >/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.plexapp.plexmediaserver</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Plex Media Server.app/Contents/MacOS/Plex Media Server</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR</key>
        <string>${PLEX_NEW_CONFIG}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/plex-error.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/plex-out.log</string>
</dict>
</plist>
EOF

  check_success "Plex LaunchAgent creation"

  # Load the LaunchAgent for the operator user
  log "Loading Plex LaunchAgent for operator user..."
  sudo -u "${OPERATOR_USERNAME}" launchctl load "${PLIST_FILE}"
  check_success "Plex LaunchAgent loading"

  log "✅ Plex configured to start automatically for ${OPERATOR_USERNAME}"
}

# Start Plex Media Server
start_plex() {
  section "Starting Plex Media Server"

  # Set environment variable for current session to use shared config
  export PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR="${PLEX_NEW_CONFIG}"

  # Start Plex as the current user first for initial setup
  log "Starting Plex Media Server for initial configuration..."
  log "Using shared configuration directory: ${PLEX_NEW_CONFIG}"
  open "/Applications/Plex Media Server.app"

  # Wait a moment for startup
  sleep 5

  # Check if Plex is running
  if pgrep -f "Plex Media Server" >/dev/null; then
    log "✅ Plex Media Server is running"
    log "Access your Plex server at:"
    log "  Local: http://localhost:32400/web"
    log "  Network: http://${HOSTNAME}.local:32400/web"
  else
    log "❌ Plex Media Server failed to start"
    log "Try starting manually with: PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR='${PLEX_NEW_CONFIG}' open '/Applications/Plex Media Server.app'"
  fi
}

# Main execution
main() {
  section "Plex Media Server Setup"
  log "Starting native Plex setup for ${HOSTNAME}"
  log "Media mount target: ${PLEX_MEDIA_MOUNT}"
  log "Server name: ${PLEX_SERVER_NAME}"

  # Confirm setup
  if ! confirm "Set up native Plex Media Server?" "y"; then
    log "Setup cancelled by user"
    exit 0
  fi

  # Setup SMB mount if not skipped
  if [[ "${SKIP_MOUNT}" != "true" ]]; then
    setup_smb_mount
  else
    log "Skipping SMB mount setup (--skip-mount specified)"
  fi

  # Install Plex
  install_plex

  # Setup shared configuration directory
  setup_shared_config

  # Migrate configuration if available
  migrate_plex_config

  # Configure auto-start
  configure_plex_autostart

  # Start Plex
  start_plex

  section "Setup Complete"
  log "✅ Native Plex Media Server setup completed successfully"
  log "Configuration directory: ${PLEX_NEW_CONFIG}"
  log "Media directory: ${PLEX_MEDIA_MOUNT}"

  if [[ "${SKIP_MOUNT}" != "true" ]]; then
    log "The media directory will auto-mount when accessed"
  fi
}

# Run main function
main "$@"
