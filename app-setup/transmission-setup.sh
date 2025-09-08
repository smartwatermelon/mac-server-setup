#!/usr/bin/env bash
#
# transmission-setup.sh - Transmission BitTorrent client setup script for Mac Mini server
#
# This script sets up Transmission on macOS with:
# - Native Transmission installation via Homebrew cask
# - Complete preferences configuration via defaults commands
# - SMB mount integration for media pipeline
# - Remote access (RPC) configuration
# - Auto-start configuration via LaunchAgent for operator
#
# Usage: ./transmission-setup.sh [--force] [--skip-mount] [--rpc-password PASSWORD]
#   --force: Skip all confirmation prompts
#   --skip-mount: Skip SMB mount setup verification
#   --rpc-password: Override RPC password (default: from config or hostname)
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
  NAS_USERNAME="${NAS_USERNAME:-transmission}"
  NAS_HOSTNAME="${NAS_HOSTNAME:-nas.local}"
  NAS_SHARE_NAME="${NAS_SHARE_NAME:-Media}"
else
  echo "❌ Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Derive configuration variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Transmission configuration paths
TRANSMISSION_APP_SUPPORT_DIR="/Users/Shared/Transmission"
TRANSMISSION_DOWNLOADS_DIR="${TRANSMISSION_APP_SUPPORT_DIR}/Downloads"
TRANSMISSION_INCOMPLETE_DIR="${TRANSMISSION_APP_SUPPORT_DIR}/Incomplete"
TRANSMISSION_DONE_SCRIPT="/usr/local/bin/transmission-done.sh"

# Media mount path (matches plex-setup.sh pattern)
MEDIA_MOUNT="${HOME}/.local/mnt/${NAS_SHARE_NAME}"

# Parse command line arguments
FORCE=false
SKIP_MOUNT=false
RPC_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --skip-mount)
      SKIP_MOUNT=true
      shift
      ;;
    --rpc-password)
      RPC_PASSWORD="$2"
      shift 2
      ;;
    *)
      echo "❌ Unknown option: $1"
      echo "Usage: $0 [--force] [--skip-mount] [--rpc-password PASSWORD]"
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

# Error and warning collection arrays
declare -a COLLECTED_ERRORS
declare -a COLLECTED_WARNINGS
CURRENT_SECTION="Initialization"

# Logging functions (matching established pattern)
log() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${timestamp} [Transmission Setup] ${message}" | tee -a "${APP_LOG_FILE}"
}

section() {
  local section_name="$1"
  CURRENT_SECTION="${section_name}"
  log ""
  log "=== ${section_name} ==="
}

set_section() {
  CURRENT_SECTION="$1"
}

collect_error() {
  local error_msg="$1"
  COLLECTED_ERRORS+=("${CURRENT_SECTION}: ${error_msg}")
  log "❌ ERROR: ${error_msg}"
}

collect_warning() {
  local warning_msg="$1"
  COLLECTED_WARNINGS+=("${CURRENT_SECTION}: ${warning_msg}")
  log "⚠️  WARNING: ${warning_msg}"
}

show_collected_issues() {
  if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]] || [[ ${#COLLECTED_WARNINGS[@]} -gt 0 ]]; then
    log ""
    log "=== Issue Summary ==="

    if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
      log ""
      log "❌ ERRORS (${#COLLECTED_ERRORS[@]}):"
      for error in "${COLLECTED_ERRORS[@]}"; do
        log "  • ${error}"
      done
    fi

    if [[ ${#COLLECTED_WARNINGS[@]} -gt 0 ]]; then
      log ""
      log "⚠️  WARNINGS (${#COLLECTED_WARNINGS[@]}):"
      for warning in "${COLLECTED_WARNINGS[@]}"; do
        log "  • ${warning}"
      done
    fi
    log ""
  fi
}

check_success() {
  local operation="$1"
  local exit_code="${2:-$?}"

  if [[ ${exit_code} -ne 0 ]]; then
    collect_error "${operation} failed (exit code: ${exit_code})"
    return 1
  else
    log "✅ ${operation} completed successfully"
    return 0
  fi
}

# Confirmation function
confirm() {
  local prompt="$1"
  local default="${2:-Y}"

  if [[ "${FORCE}" == true ]]; then
    log "Auto-confirmed (--force): ${prompt}"
    return 0
  fi

  local response
  if [[ "${default}" == "Y" ]]; then
    read -p "${prompt} (Y/n): " -r response
    case "${response}" in
      [nN] | [nN][oO]) return 1 ;;
      *) return 0 ;;
    esac
  else
    read -p "${prompt} (y/N): " -r response
    case "${response}" in
      [yY] | [yY][eE][sS]) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

# Start setup
section "Transmission BitTorrent Client Setup"
log "Starting Transmission setup for ${HOSTNAME}"
log "Operator: ${OPERATOR_USERNAME}"
log "RPC Access: ${HOSTNAME_LOWER}.local:19091"

# Verify SMB mount unless skipped
if [[ "${SKIP_MOUNT}" != true ]]; then
  section "Verifying Media Mount"
  set_section "Media Mount Verification"

  if [[ -d "${MEDIA_MOUNT}" ]]; then
    mount_contents=$(ls -A "${MEDIA_MOUNT}" 2>/dev/null)
    if [[ -n "${mount_contents}" ]]; then
      log "✅ Media mount verified at ${MEDIA_MOUNT}"
    else
      collect_warning "Media mount directory exists but appears empty at ${MEDIA_MOUNT}"
      log "Run mount-nas-media.sh first or use --skip-mount to proceed without mount verification"
    fi
  else
    collect_warning "Media mount not found at ${MEDIA_MOUNT}"
    log "Run mount-nas-media.sh first or use --skip-mount to proceed without mount verification"
  fi
fi

# Check if Transmission is installed
section "Transmission Installation Check"
set_section "Installation Verification"

if [[ -d "/Applications/Transmission.app" ]]; then
  log "✅ Transmission.app found in /Applications/"
else
  log "Transmission not found. Installing via Homebrew..."
  if brew install --cask transmission; then
    check_success "Transmission installation"
  else
    collect_error "Failed to install Transmission via Homebrew"
    exit 1
  fi
fi

# Get Transmission version
if command -v /Applications/Transmission.app/Contents/MacOS/Transmission >/dev/null 2>&1; then
  TRANSMISSION_VERSION=$(defaults read /Applications/Transmission.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown")
  log "Transmission version: ${TRANSMISSION_VERSION}"
fi

# Confirm setup
if ! confirm "Set up Transmission with downloads to ${TRANSMISSION_DOWNLOADS_DIR} and RPC access on port 19091?"; then
  log "Setup cancelled by user"
  exit 0
fi

# Stop Transmission if running (required for configuration changes)
section "Stopping Transmission for Configuration"
set_section "Application Control"

if pgrep -x "Transmission" >/dev/null 2>&1; then
  log "Stopping Transmission for configuration changes..."
  if sudo -iu "${OPERATOR_USERNAME}" osascript -e 'quit app "Transmission"' 2>/dev/null; then
    sleep 2
    check_success "Transmission shutdown"
  else
    log "Attempting force quit..."
    if sudo -iu "${OPERATOR_USERNAME}" killall "Transmission" 2>/dev/null; then
      sleep 2
      check_success "Transmission force quit"
    else
      log "Transmission was not running or already stopped"
    fi
  fi
fi

# Create shared directories with proper permissions
section "Creating Shared Directories"
set_section "Directory Creation"

for dir in "${TRANSMISSION_APP_SUPPORT_DIR}" "${TRANSMISSION_DOWNLOADS_DIR}" "${TRANSMISSION_INCOMPLETE_DIR}"; do
  if [[ ! -d "${dir}" ]]; then
    log "Creating directory: ${dir}"
    if sudo mkdir -p "${dir}"; then
      sudo chown admin:staff "${dir}"
      sudo chmod 775 "${dir}"
      check_success "Directory creation: ${dir}"
    else
      collect_error "Failed to create directory: ${dir}"
    fi
  else
    log "✅ Directory exists: ${dir}"
  fi
done

# Configure Transmission preferences via defaults
section "Configuring Transmission Preferences"
set_section "Preferences Configuration"

log "Applying Transmission configuration via defaults commands..."

# Download and storage settings
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DownloadFolder -string "${TRANSMISSION_DOWNLOADS_DIR}"
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission UseIncompleteDownloadFolder -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission IncompleteDownloadFolder -string "${TRANSMISSION_INCOMPLETE_DIR}"
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DeleteOriginalTorrent -bool true

# UI and confirmation settings
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DownloadAsk -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission MagnetOpenAsk -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission AutoStartDownload -bool true

# RPC (Remote Procedure Call) settings for web interface
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCEnabled -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCAuthenticationRequired -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCUsername -string "${HOSTNAME_LOWER}"
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCPassword -string "${RPC_PASSWORD}"
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCPort -int 19091
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCHostWhitelistEnabled -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RPCHostWhitelist -string "${HOSTNAME_LOWER}.local"

# Network settings
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission RandomPort -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission NatTraversal -bool true

# Speed and queue settings
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission SpeedLimit -bool false
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission QueueDownloadEnabled -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission QueueDownloadNumber -int 5
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission QueueSeedEnabled -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission QueueSeedNumber -int 10

check_success "Transmission preferences configuration"

# Create completion script (for FileBot integration later)
section "Creating Completion Script"
set_section "Script Creation"

log "Creating transmission-done.sh completion script..."
sudo tee "${TRANSMISSION_DONE_SCRIPT}" >/dev/null <<'EOF'
#!/usr/bin/env bash
#
# transmission-done.sh - Transmission completion script
# Called when a torrent finishes downloading
#
# Environment variables provided by Transmission:
# TR_APP_VERSION, TR_TIME_LOCALTIME, TR_TORRENT_DIR, TR_TORRENT_HASH,
# TR_TORRENT_ID, TR_TORRENT_NAME

# Log completion
LOG_FILE="${HOME}/.local/state/transmission-completion.log"
mkdir -p "$(dirname "${LOG_FILE}")"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Torrent completed: ${TR_TORRENT_NAME:-unknown}" >> "${LOG_FILE}"

# Future: FileBot integration will be added here
# filebot -rename "${TR_TORRENT_DIR}/${TR_TORRENT_NAME}" --output /path/to/media/library

exit 0
EOF

sudo chmod +x "${TRANSMISSION_DONE_SCRIPT}"
check_success "Completion script creation"

# Configure completion script in Transmission
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DoneScriptEnabled -bool true
sudo -iu "${OPERATOR_USERNAME}" defaults write org.m0k.transmission DoneScript -string "${TRANSMISSION_DONE_SCRIPT}"

# Create LaunchAgent for auto-start
section "Creating LaunchAgent for Auto-Start"
set_section "LaunchAgent Creation"

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
  <key>LaunchOnlyOnce</key>
  <true/>
</dict>
</plist>
EOF

check_success "LaunchAgent creation"

# Set proper permissions on LaunchAgent
sudo chown "${OPERATOR_USERNAME}:staff" "${LAUNCHAGENT_PLIST}"
sudo chmod 644 "${LAUNCHAGENT_PLIST}"

# Load LaunchAgent for operator
log "Loading LaunchAgent for operator..."
if sudo -iu "${OPERATOR_USERNAME}" launchctl load "${LAUNCHAGENT_PLIST}" 2>/dev/null; then
  check_success "LaunchAgent loaded"
else
  log "LaunchAgent will be loaded on next operator login"
fi

# Setup complete
section "Setup Complete"
log ""
log "🎉 Transmission setup completed successfully!"
log ""
log "Configuration Summary:"
log "  • App: /Applications/Transmission.app"
log "  • Downloads: ${TRANSMISSION_DOWNLOADS_DIR}"
log "  • Incomplete: ${TRANSMISSION_INCOMPLETE_DIR}"
log "  • Web Interface: http://${HOSTNAME_LOWER}.local:19091"
log "  • Username: ${HOSTNAME_LOWER}"
log "  • Password: ${RPC_PASSWORD}"
log "  • Auto-start: Enabled for operator login"
log ""
log "Access the web interface at: http://${HOSTNAME_LOWER}.local:19091"
log "Use credentials: ${HOSTNAME_LOWER} / ${RPC_PASSWORD}"
log ""

# Show any collected issues
show_collected_issues

# Exit with error code if there were errors
if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
  log "Setup completed with ${#COLLECTED_ERRORS[@]} error(s)"
  exit 1
else
  log "Setup completed successfully with no errors"
  exit 0
fi
