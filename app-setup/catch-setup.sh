#!/usr/bin/env bash
#
# catch-setup.sh - Catch RSS reader setup script for Mac Mini server
#
# This script sets up Catch RSS reader on macOS with:
# - Native Catch installation via Homebrew cask (if not already installed)
# - RSS feeds configuration
# - Download path configuration to match Dropbox sync directory
# - Auto-start configuration via LaunchAgent for operator
#
# Usage: ./catch-setup.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude
# Version: 1.0
# Created: 2025-09-09

# Exit on error
set -euo pipefail

# Ensure Homebrew environment is available
# Don't rely on profile files - set up Homebrew PATH directly
HOMEBREW_PREFIX="/opt/homebrew" # Apple Silicon
if [[ -x "${HOMEBREW_PREFIX}/bin/brew" ]]; then
  # Apply Homebrew environment directly
  brew_env=$("${HOMEBREW_PREFIX}/bin/brew" shellenv)
  eval "${brew_env}"
  echo "Homebrew environment configured for Catch setup"
elif command -v brew >/dev/null 2>&1; then
  # Homebrew is already in PATH
  echo "Homebrew already available in current environment"
else
  echo "❌ Homebrew not found - Catch setup requires Homebrew"
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
  echo "  cd $(dirname "${SCRIPT_DIR}")/app-setup"
  echo "  ./$(basename "${0}")"
  exit 1
fi

# Load configuration
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "❌ Error: Configuration file not found: ${CONFIG_FILE}"
  echo ""
  echo "Please create config/config.conf from config/config.conf.template"
  echo "and configure your settings before running this script."
  exit 1
fi

# Load configuration
# shellcheck source=config/config.conf
source "${CONFIG_FILE}"

# Computed variables
# Derive configuration variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

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
  echo "${timestamp} [Catch Setup] ${message}" | tee -a "${APP_LOG_FILE}"
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
    [yY]) return 0 ;;
    [nN]) return 1 ;;
    *) return 1 ;;
  esac
}

# Argument parsing
FORCE=false
for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "❌ Error: Unknown option: ${arg}"
      echo ""
      echo "Usage: $0 [--force]"
      echo "  --force: Skip all confirmation prompts"
      exit 1
      ;;
  esac
done

log "Starting Catch RSS reader setup for ${SERVER_NAME}"
log "Operator account: ${OPERATOR_USERNAME}"
log "Configuration loaded from: ${CONFIG_FILE}"

# Command line argument information
if [[ "${FORCE}" == true ]]; then
  log "Running in force mode (skipping confirmations)"
fi

# Validate required configuration
if [[ -z "${OPERATOR_USERNAME}" ]]; then
  echo "❌ Error: OPERATOR_USERNAME not set in configuration"
  exit 1
fi

if [[ -z "${CATCH_FEEDS_URL:-}" ]]; then
  log "⚠️  CATCH_FEEDS_URL not configured - Catch will start with no feeds"
fi

# Configure Dropbox sync path with fallback
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
DROPBOX_PATH="${DROPBOX_LOCAL_PATH:-${OPERATOR_HOME}/.local/sync/dropbox}"

# Install Catch via Homebrew if not already installed
install_catch() {
  section "Installing Catch RSS Reader"

  if brew list --cask catch >/dev/null 2>&1; then
    log "✅ Catch is already installed"
    return 0
  fi

  log "Installing Catch via Homebrew..."
  if brew install --cask catch; then
    log "✅ Catch installation completed successfully"
  else
    echo "❌ Error: Failed to install Catch via Homebrew"
    exit 1
  fi
}

# Configure Catch preferences
configure_catch_preferences() {
  section "Configuring Catch Preferences"

  log "Configuring Catch preferences for operator: ${OPERATOR_USERNAME}"
  log "Save path: ${DROPBOX_PATH}"

  # Create the preferences plist
  local prefs_plist="org.giorgiocalderolla.Catch"

  # Set basic preferences
  sudo -iu "${OPERATOR_USERNAME}" defaults write "${prefs_plist}" NSNavLastRootDirectory -string "${DROPBOX_PATH}"
  sudo -iu "${OPERATOR_USERNAME}" defaults write "${prefs_plist}" savePath -string "${DROPBOX_PATH}"

  # Set automatic update checking
  sudo -iu "${OPERATOR_USERNAME}" defaults write "${prefs_plist}" SUEnableAutomaticChecks -bool true

  # Configure feeds if URL provided
  if [[ -n "${CATCH_FEEDS_URL:-}" ]]; then
    log "Configuring RSS feed: ${CATCH_FEEDS_URL}"

    # Create feeds array - Catch expects an array of dictionaries
    # Use direct array-add with quoted dictionary syntax (the only approach that works)
    sudo -iu "${OPERATOR_USERNAME}" defaults write "${prefs_plist}" feeds -array-add \
      "{ name = ShowRSS; url = \"${CATCH_FEEDS_URL}\"; }"

    # Configure history cutoff to prevent re-downloading old torrents
    local cutoff_days="${CATCH_HISTORY_CUTOFF_DAYS:-7}"
    if [[ "${cutoff_days}" -gt 0 ]]; then
      log "Setting up history cutoff: ${cutoff_days} days back"

      # Calculate cutoff date (N days ago at midnight UTC)
      local cutoff_date
      if command -v gdate >/dev/null 2>&1; then
        # Use GNU date if available (from coreutils via Homebrew)
        cutoff_date=$(gdate -u -d "${cutoff_days} days ago" '+%Y-%m-%d 00:00:00 +0000')
      else
        # Fallback to macOS date (limited functionality)
        cutoff_date=$(date -u -v-"${cutoff_days}d" '+%Y-%m-%d 00:00:00 +0000')
      fi

      log "History cutoff date: ${cutoff_date}"

      # Create a dummy history entry to establish cutoff - Catch will not re-download
      # anything it thinks it has already processed before this date
      sudo -iu "${OPERATOR_USERNAME}" defaults write "${prefs_plist}" history -array-add \
        "{ date = \"${cutoff_date}\"; feed = { name = ShowRSS; url = \"${CATCH_FEEDS_URL}\"; }; showName = \"SETUP_CUTOFF\"; title = \"Setup cutoff - preventing downloads before ${cutoff_date}\"; url = \"magnet:?xt=urn:btih:0000000000000000000000000000000000000000\"; }"

      log "✅ History cutoff configured - will not re-download content older than ${cutoff_days} days"
    else
      log "History cutoff disabled (CATCH_HISTORY_CUTOFF_DAYS=0) - may download all available content"
    fi
  else
    log "No CATCH_FEEDS_URL configured - skipping feed setup"
  fi

  log "✅ Catch preferences configured successfully"
}

# Create LaunchAgent for auto-start
create_launch_agent() {
  section "Creating LaunchAgent for Auto-Start"

  local launchagent_dir="${OPERATOR_HOME}/Library/LaunchAgents"
  local launchagent_plist="${launchagent_dir}/com.${HOSTNAME_LOWER}.catch.plist"

  log "Creating LaunchAgent: ${launchagent_plist}"

  # Ensure LaunchAgent directory exists
  if [[ ! -d "${launchagent_dir}" ]]; then
    sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${launchagent_dir}"
  fi

  sudo -iu "${OPERATOR_USERNAME}" tee "${launchagent_plist}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.${HOSTNAME_LOWER}.catch</string>
    <key>Program</key>
    <string>/Applications/Catch.app/Contents/MacOS/Catch</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

  # Validate plist syntax
  if sudo plutil -lint "${launchagent_plist}" >/dev/null 2>&1; then
    log "Catch LaunchAgent plist syntax validated successfully"
  else
    echo "❌ Error: Invalid plist syntax in ${launchagent_plist}"
    exit 1
  fi

  log "✅ LaunchAgent creation completed successfully"

  # Set proper permissions on LaunchAgent
  sudo chown "${OPERATOR_USERNAME}:staff" "${launchagent_plist}"
  sudo chmod 644 "${launchagent_plist}"
}

# Main setup function
main() {
  section "Catch RSS Reader Setup"

  if [[ "${FORCE}" != true ]]; then
    echo ""
    echo "This will set up Catch RSS reader with the following configuration:"
    echo "  • Operator account: ${OPERATOR_USERNAME}"
    echo "  • Save path: ${DROPBOX_PATH}"
    if [[ -n "${CATCH_FEEDS_URL:-}" ]]; then
      echo "  • RSS feed: ${CATCH_FEEDS_URL}"
      local cutoff_days="${CATCH_HISTORY_CUTOFF_DAYS:-7}"
      if [[ "${cutoff_days}" -gt 0 ]]; then
        echo "  • History cutoff: ${cutoff_days} days (prevents re-downloading old content)"
      else
        echo "  • History cutoff: Disabled (may download all available content)"
      fi
    else
      echo "  • RSS feed: Not configured (can be added manually)"
    fi
    echo "  • Auto-start: Yes (via LaunchAgent)"
    echo ""

    if ! confirm "Continue with Catch setup?" "Y"; then
      log "Setup cancelled by user"
      exit 0
    fi
  fi

  # Ensure save directory exists
  if [[ ! -d "${DROPBOX_PATH}" ]]; then
    log "Creating save directory: ${DROPBOX_PATH}"
    sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${DROPBOX_PATH}"
  fi

  # Run setup steps
  install_catch
  configure_catch_preferences
  create_launch_agent

  # Setup complete
  section "Setup Complete"

  log ""
  log "🎉 Catch RSS reader setup completed successfully!"
  log ""
  log "Configuration:"
  log "  • Application: /Applications/Catch.app"
  log "  • Operator account: ${OPERATOR_USERNAME}"
  log "  • Save path: ${DROPBOX_PATH}"
  if [[ -n "${CATCH_FEEDS_URL:-}" ]]; then
    log "  • RSS feed configured: ${CATCH_FEEDS_URL}"
  else
    log "  • RSS feeds: None configured (add manually in app)"
  fi
  log "  • Auto-start: Configured via LaunchAgent"
  log ""
  log "Next Steps:"
  log "  1. Log in as '${OPERATOR_USERNAME}' to activate the LaunchAgent"
  log "  2. Catch will start automatically and appear in the menu bar"
  if [[ -z "${CATCH_FEEDS_URL:-}" ]]; then
    log "  3. Add RSS feeds manually in the Catch application"
  fi
  log "  4. Downloaded content will be saved to: ${DROPBOX_PATH}"
}

# Run main function
main "$@"
