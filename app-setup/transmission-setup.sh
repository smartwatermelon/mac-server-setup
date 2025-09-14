#!/usr/bin/env bash
#
# transmission-setup.sh - Transmission BitTorrent Client with Complete GUI Automation
#
# This script provides comprehensive Transmission setup including:
# - Native Transmission installation via Homebrew cask with version detection
# - ~95% GUI preference automation using verified plist keys only
# - Magnet link handler configuration via Launch Services integration
# - Media pipeline integration with download paths and completion scripts
# - RPC web interface with authentication and remote access at port 19091
# - LaunchAgent configuration for automatic startup with operator login
# - Network configuration: peer settings, encryption, port mapping, blocklist
#
# SYSTEM INTEGRATION:
# - Configures Transmission as default magnet link application
# - Creates FileBot integration completion script template
# - Integrates with rclone sync directory for automated processing
# - Supports complete media pipeline: Catch → Transmission → FileBot → Plex
#
# PREFERENCES AUTOMATED (~95% GUI coverage):
# - Download management: paths, seeding limits, completion handling
# - Network settings: fixed peer port (40944), UPnP, µTP protocol
# - UI settings: auto-resize, confirmation prompts, watch folder
# - Security: RPC authentication, whitelist configuration
# - File handling: delete original torrents, download confirmation
#
# Usage: ./transmission-setup.sh [--force] [--rpc-password PASSWORD]
#   --force: Skip all confirmation prompts
#   --rpc-password: Override RPC web interface password (default: auto-generated from hostname)
#
# Author: Claude
# Version: 1.0
# Created: 2025-09-08

# Exit on error
set -euo pipefail

# Ensure Homebrew environment is available
# Don't rely on profile files - set up Homebrew PATH directly
HOMEBREW_PREFIX="/opt/homebrew" # Apple Silicon
if [[ -x "${HOMEBREW_PREFIX}/bin/brew" ]]; then
  # Apply Homebrew environment directly
  brew_env=$("${HOMEBREW_PREFIX}/bin/brew" shellenv)
  eval "${brew_env}"
  echo "Homebrew environment configured for Transmission setup"
elif command -v brew >/dev/null 2>&1; then
  # Homebrew is already in PATH
  echo "Homebrew already available in current environment"
else
  echo "❌ Homebrew not found - Transmission setup requires Homebrew"
  echo "Please ensure first-boot.sh completed successfully before running app setup"
  exit 1
fi

# Determine script directory first
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate working directory before loading config
if [[ "${PWD}" != "${SCRIPT_DIR}" ]] || [[ "$(basename "${SCRIPT_DIR}")" != "app-setup" ]]; then
  echo "❌ Error: This script must be run from the app-setup directory"
  echo ""
  echo "Current directory: ${PWD}"
  echo "Script directory: ${SCRIPT_DIR}"
  echo ""
  echo "Please change to the app-setup directory and try again:"
  echo "  cd \"${SCRIPT_DIR}\" && ./transmission-setup.sh"
  echo ""
  exit 1
fi

# Load server configuration
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
  NAS_SHARE_NAME="${NAS_SHARE_NAME:-Media}"
else
  echo "❌ Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Derive configuration variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Operator home directory (for path construction)
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"

# Transmission configuration paths (matching original configuration)
TRANSMISSION_DOWNLOADS_DIR="${OPERATOR_HOME}/.local/mnt/${NAS_SHARE_NAME}/Media/Torrents/pending-move"
TRANSMISSION_DONE_SCRIPT="${OPERATOR_HOME}/.local/bin/transmission-done.sh"

# Parse command line arguments
FORCE=false
RPC_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --rpc-password)
      RPC_PASSWORD="$2"
      shift 2
      ;;
    *)
      echo "❌ Unknown option: $1"
      echo "Usage: $0 [--force] [--rpc-password PASSWORD]"
      exit 1
      ;;
  esac
done

# Set RPC password if not provided
if [[ -z "${RPC_PASSWORD}" ]]; then
  RPC_PASSWORD="${HOSTNAME_LOWER}"
fi

# Logging configuration
APP_LOG_DIR="${HOME}/.local/state"
APP_LOG_FILE="${APP_LOG_DIR}/${HOSTNAME_LOWER}-apps.log"

# Ensure log directory exists
if [[ ! -d "${APP_LOG_DIR}" ]]; then
  mkdir -p "${APP_LOG_DIR}"
fi

# Logging functions (matching established pattern)
log() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${timestamp} [Transmission Setup] ${message}" | tee -a "${APP_LOG_FILE}"
}

section() {
  local section_name="$1"
  log ""
  log "=== ${section_name} ==="
}

# Confirmation function
confirm() {
  local prompt="$1"
  local default="${2:-y}"

  # In force mode, respect the default behavior instead of always returning YES
  if [[ "${FORCE}" == "true" ]]; then
    if [[ "${default}" == "y" ]]; then
      return 0 # Default YES - auto-confirm
    else
      return 1 # Default NO - auto-decline
    fi
  fi

  if [[ "${default}" == "y" ]]; then
    read -rp "${prompt} (Y/n): " -n 1 response
    echo
    response=${response:-y}
  else
    read -rp "${prompt} (y/N): " -n 1 response
    echo
    response=${response:-n}
  fi

  case "${response}" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Start setup
section "Transmission BitTorrent Client Setup"
log "Starting Transmission setup for ${HOSTNAME}"
log "Operator: ${OPERATOR_USERNAME}"
log "RPC Access: ${HOSTNAME_LOWER}.local:19091"

# Check if Transmission is installed
section "Transmission Installation Check"

if [[ -d "/Applications/Transmission.app" ]]; then
  log "✅ Transmission.app found in /Applications/"
else
  log "Transmission not found. Installing via Homebrew..."
  if brew install --cask transmission; then
    log "✅ Transmission installation completed successfully"
  else
    log "❌ ERROR: Failed to install Transmission via Homebrew"
    exit 1
  fi
fi

# Get Transmission version
if command -v /Applications/Transmission.app/Contents/MacOS/Transmission >/dev/null 2>&1; then
  TRANSMISSION_VERSION=$(defaults read /Applications/Transmission.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown")
  log "Transmission version: ${TRANSMISSION_VERSION}"
fi

# Confirm setup
if ! confirm "Set up Transmission with downloads to operator's media mount and RPC access on port 19091?" "y"; then
  log "Setup cancelled by user"
  exit 0
fi

# Stop Transmission if running (required for configuration changes)
section "Stopping Transmission for Configuration"

if pgrep -x "Transmission" >/dev/null 2>&1; then
  log "Stopping Transmission for configuration changes..."
  if sudo -iu "${OPERATOR_USERNAME}" osascript -e 'quit app "Transmission"' 2>/dev/null; then
    sleep 2
    log "✅ Transmission shutdown completed successfully"
  else
    log "Attempting force quit..."
    if sudo -iu "${OPERATOR_USERNAME}" killall "Transmission" 2>/dev/null; then
      sleep 2
      log "✅ Transmission force quit completed successfully"
    else
      log "Transmission was not running or already stopped"
    fi
  fi
fi

# Ensure directories exist
section "Verifying Download Directories"

# The downloads directory is on the media mount, managed by mount-nas-media.sh
log "Downloads directory (on media mount): ${TRANSMISSION_DOWNLOADS_DIR}"

# Note: AutoImport directory is managed by rclone-setup.sh at ${OPERATOR_HOME}/.local/sync/dropbox
log "Auto-import directory (rclone sync): ${OPERATOR_HOME}/.local/sync/dropbox"

# Configure Transmission preferences via defaults
section "Configuring Transmission Preferences"

log "Applying Transmission configuration via defaults commands..."

# Download and storage settings
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DownloadFolder -string "${TRANSMISSION_DOWNLOADS_DIR}"
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DownloadLocationConstant -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission UseIncompleteDownloadFolder -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DeleteOriginalTorrent -bool true

# UI and confirmation settings
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DownloadAsk -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission MagnetOpenAsk -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission AutoStartDownload -bool true

# Warning/prompt settings (issues #1, #2)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission CheckRemove -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission CheckQuit -bool false

# RPC (Remote Procedure Call) settings for web interface (issue #6)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPC -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCAuthenticationRequired -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCUsername -string "${HOSTNAME_LOWER}"
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCPassword -string "${RPC_PASSWORD}"
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCPort -int 19091
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCUseWhitelist -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCWhitelist -array "0.0.0.0" "127.0.0.1"

# Network settings (verified keys from actual plist)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission BindPort -int 40944
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission NatTraversal -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission UTPGlobal -bool true

# Peer settings (verified keys from actual plist)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission PeersTotal -int 2048
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission PeersTorrent -int 256
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission PEXGlobal -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DHTGlobal -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission LocalPeerDiscoveryGlobal -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission EncryptionPrefer -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission EncryptionRequire -bool true

# Blocklist settings (verified keys from actual plist)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission BlocklistNew -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission BlocklistURL -string "https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz"
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission BlocklistAutoUpdate -bool true

# Speed and queue settings (verified keys from actual plist)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission SpeedLimit -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission SpeedLimitDownloadLimit -int 100000
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission SpeedLimitUploadLimit -int 1000
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission Queue -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission QueueDownloadNumber -int 3
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission QueueSeed -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission QueueSeedNumber -int 3

# Seeding limits (verified keys from actual plist)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RatioCheck -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RatioLimit -int 2
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission IdleLimitCheck -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission IdleLimitMinutes -int 30
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RemoveWhenFinishSeeding -bool true

# Stalled transfer settings (verified keys from actual plist)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission CheckStalled -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission StalledMinutes -int 30

# UI and notification settings (matching GUI: General tab)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission AutoSize -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission SUHasLaunchedBefore -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission SUUpdateRelaunchingMarker -bool false

# Watch folder settings (verified keys from actual plist, using rclone sync directory)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission AutoImport -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission AutoImportDirectory -string "${OPERATOR_HOME}/.local/sync/dropbox"

log "✅ Transmission preferences configuration completed successfully"

# Configure magnet link handler in Launch Services
section "Configuring Magnet Link Handler"

log "Setting Transmission as default application for magnet links..."

# Add magnet link handler to Launch Services
sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers -array-add '{
    LSHandlerURLScheme = "magnet";
    LSHandlerRoleAll = "org.m0k.transmission";
    LSHandlerPreferredVersions = {
        LSHandlerRoleAll = "-";
    };
}'

log "✅ Magnet link handler configuration completed successfully"

# Create completion script (for FileBot integration later)
section "Creating Completion Script"

log "Copying transmission-done.sh completion script from template..."
OPERATOR_LOCAL_BIN="$(dirname "${TRANSMISSION_DONE_SCRIPT}")"
sudo mkdir -p "${OPERATOR_LOCAL_BIN}"

# Copy template script to destination
sudo cp "${SCRIPT_DIR}/templates/transmission-done.sh" "${TRANSMISSION_DONE_SCRIPT}"
sudo chmod +x "${TRANSMISSION_DONE_SCRIPT}"
sudo chown -v "${OPERATOR_USERNAME}" "${TRANSMISSION_DONE_SCRIPT}"
log "✅ Completion script creation completed successfully"

# Configure completion script in Transmission (issue #5)
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DoneScriptEnabled -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DoneScriptPath -string "${TRANSMISSION_DONE_SCRIPT}"

# Create LaunchAgent for auto-start
section "Creating LaunchAgent for Auto-Start"

OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
LAUNCHAGENT_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
LAUNCHAGENT_PLIST="${LAUNCHAGENT_DIR}/com.${HOSTNAME_LOWER}.transmission.plist"

log "Creating LaunchAgent: ${LAUNCHAGENT_PLIST}"

# Ensure LaunchAgent directory exists
if [[ ! -d "${LAUNCHAGENT_DIR}" ]]; then
  sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${LAUNCHAGENT_DIR}"
fi

sudo -iu "${OPERATOR_USERNAME}" tee "${LAUNCHAGENT_PLIST}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.transmission</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>Transmission</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF

# Validate plist syntax
if sudo plutil -lint "${LAUNCHAGENT_PLIST}" >/dev/null 2>&1; then
  log "Transmission LaunchAgent plist syntax validated successfully"
else
  log "Invalid plist syntax in ${LAUNCHAGENT_PLIST}"
  return 1
fi

log "✅ LaunchAgent creation completed successfully"

# Set proper permissions on LaunchAgent
sudo chown "${OPERATOR_USERNAME}:staff" "${LAUNCHAGENT_PLIST}"
sudo chmod 644 "${LAUNCHAGENT_PLIST}"

# Setup complete
section "Setup Complete"
log ""
log "🎉 Transmission setup completed successfully!"
log ""
log "Configuration Summary:"
log "  • App: /Applications/Transmission.app"
log "  • Downloads: ${TRANSMISSION_DOWNLOADS_DIR}"
log "  • Web Interface: http://${HOSTNAME_LOWER}.local:19091"
log "  • Username: ${HOSTNAME_LOWER}"
log "  • Password: ${RPC_PASSWORD}"
log "  • Auto-start: Enabled for operator login"
log ""
log "Access the web interface at: http://${HOSTNAME_LOWER}.local:19091"
log "Use credentials: ${HOSTNAME_LOWER} / ${RPC_PASSWORD}"
log ""

log "Setup completed successfully"
exit 0
