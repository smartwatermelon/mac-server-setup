#!/usr/bin/env bash
#
# filebot-setup.sh - FileBot media processing setup script for Mac Mini server
#
# This script sets up FileBot on macOS with:
# - Native FileBot installation via Homebrew cask (if not already installed)
# - License file installation and activation
# - Media processing format templates matching NAS mount paths
# - OpenSubtitles configuration for subtitle downloading
# - Integration with transmission and media pipeline
#
# Usage: ./filebot-setup.sh [--force] [--license-file PATH]
#   --force: Skip all confirmation prompts
#   --license-file: Override license file path (default: from config)
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
  echo "Homebrew environment configured for FileBot setup"
elif command -v brew >/dev/null 2>&1; then
  # Homebrew is already in PATH
  echo "Homebrew already available in current environment"
else
  echo "❌ Homebrew not found - FileBot setup requires Homebrew"
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
  echo "  cd \"${SCRIPT_DIR}\" && ./filebot-setup.sh"
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

# FileBot configuration paths
FILEBOT_CONFIG_DIR="${OPERATOR_HOME}/.local/config/filebot"
FILEBOT_MEDIA_PATH="${OPERATOR_HOME}/.local/mnt/${NAS_SHARE_NAME}/Media"

# Parse command line arguments
FORCE=false
OVERRIDE_LICENSE_FILE=""
ADMINISTRATOR_PASSWORD="${ADMINISTRATOR_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --license-file)
      OVERRIDE_LICENSE_FILE="$2"
      shift 2
      ;;
    --password)
      ADMINISTRATOR_PASSWORD="$2"
      shift 2
      ;;
    *)
      echo "❌ Unknown option: $1"
      echo "Usage: $0 [--force] [--license-file PATH]"
      exit 1
      ;;
  esac
done

# Logging setup
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-apps.log"

# Error and warning collection system
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
CURRENT_SCRIPT_SECTION=""

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  echo "====== $1 ======"
  log "====== $1 ======"
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
  log "ERROR: ${clean_message}"
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
  log "WARNING: ${clean_message}"
  COLLECTED_WARNINGS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to show collected errors and warnings at end
show_collected_issues() {
  local error_count=${#COLLECTED_ERRORS[@]}
  local warning_count=${#COLLECTED_WARNINGS[@]}

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    echo "✅ FileBot setup completed successfully with no errors or warnings!"
    log "FileBot setup completed successfully with no errors or warnings!"
    return
  fi

  echo ""
  echo "====== FILEBOT SETUP SUMMARY ======"
  echo "FileBot setup completed, but ${error_count} errors and ${warning_count} warnings occurred:"
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

  # Also log the summary
  log "FileBot setup completed with ${error_count} errors and ${warning_count} warnings"
  if [[ ${error_count} -gt 0 ]]; then
    for error in "${COLLECTED_ERRORS[@]}"; do
      log "ERROR: ${error}"
    done
  fi
  if [[ ${warning_count} -gt 0 ]]; then
    for warning in "${COLLECTED_WARNINGS[@]}"; do
      log "WARNING: ${warning}"
    done
  fi
}

# Trap to show collected issues on exit
trap 'show_collected_issues' EXIT

# Ensure we have administrator password for keychain operations
function get_administrator_password() {
  if [[ -z "${ADMINISTRATOR_PASSWORD:-}" ]]; then
    echo
    echo "This script needs your Mac account password for keychain operations."
    read -r -e -p "Enter your Mac account password: " -s ADMINISTRATOR_PASSWORD
    echo # Add newline after hidden input

    # Validate password by testing with dscl
    until _timeout 1 dscl /Local/Default -authonly "${USER}" "${ADMINISTRATOR_PASSWORD}" &>/dev/null; do
      echo "Invalid ${USER} account password. Try again or ctrl-C to exit."
      read -r -e -p "Enter your Mac ${USER} account password: " -s ADMINISTRATOR_PASSWORD
      echo # Add newline after hidden input
    done

    echo "✅ Administrator password validated for keychain operations"
  fi
}

# Logging functions
log() {
  mkdir -p "${LOG_DIR}"
  local timestamp no_newline=false
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  # Check for -n flag
  if [[ "$1" == "-n" ]]; then
    no_newline=true
    shift
  fi

  if [[ "${no_newline}" == true ]]; then
    echo -n "[${timestamp}] $1" >>"${LOG_FILE}"
  else
    echo "[${timestamp}] $1" >>"${LOG_FILE}"
  fi
}

# Function to check command success and provide error context
check_success() {
  local exit_code=$?
  local context="${1:-command}"

  if [[ ${exit_code} -ne 0 ]]; then
    collect_error "Failed: ${context} (exit code: ${exit_code})"
    return "${exit_code}"
  else
    log "Success: ${context}"
    return 0
  fi
}

# Function to get user confirmation (skip if --force)
confirm() {
  if [[ "${FORCE}" == true ]]; then
    return 0
  fi

  local prompt="${1:-Continue?}"
  local default="${2:-Y}"

  if [[ "${default}" == "Y" ]]; then
    prompt_text="${prompt} (Y/n): "
  else
    prompt_text="${prompt} (y/N): "
  fi

  read -p "${prompt_text}" -r response
  response=${response:-${default}}

  if [[ "${response}" =~ ^[Yy]$ ]]; then
    return 0
  else
    return 1
  fi
}

# Main setup function
main() {
  echo "Starting FileBot setup for ${HOSTNAME} server..."
  log "FileBot setup started for ${HOSTNAME} server"

  set_section "FileBot Installation"

  # Check if FileBot is already installed
  if brew list --cask filebot &>/dev/null; then
    echo "✅ FileBot is already installed via Homebrew"
    log "FileBot already installed via Homebrew"

    # Get version information
    filebot_version=$(defaults read /Applications/FileBot.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "unknown")
    echo "   Version: ${filebot_version}"
    log "FileBot version: ${filebot_version}"
  else
    echo "📦 Installing FileBot via Homebrew..."
    log "Installing FileBot via Homebrew cask"

    if confirm "Install FileBot?"; then
      if brew install --cask filebot; then
        check_success "FileBot installation"
        echo "✅ FileBot installed successfully"

        # Get version information
        filebot_version=$(filebot --version 2>/dev/null | head -1 | cut -d' ' -f2 || echo "unknown")
        echo "   Version: ${filebot_version}"
        log "FileBot version: ${filebot_version}"
      else
        collect_error "FileBot installation failed"
        return 1
      fi
    else
      echo "❌ FileBot installation canceled by user"
      log "FileBot installation canceled by user"
      return 1
    fi
  fi

  set_section "License File Setup"

  # Find license file
  license_file=""
  if [[ -n "${OVERRIDE_LICENSE_FILE}" ]]; then
    license_file="${OVERRIDE_LICENSE_FILE}"
    echo "Using license file from command line: ${license_file}"
  elif [[ -n "${FILEBOT_LICENSE_FILE:-}" ]]; then
    # First check if it's a full path (from config.conf)
    if [[ -f "${FILEBOT_LICENSE_FILE}" ]]; then
      license_file="${FILEBOT_LICENSE_FILE}"
      echo "Using license file from config: ${license_file}"
    else
      # Check if it's in app-setup/config directory
      config_license="${SCRIPT_DIR}/config/$(basename "${FILEBOT_LICENSE_FILE}")"
      if [[ -f "${config_license}" ]]; then
        license_file="${config_license}"
        echo "Using license file from app-setup/config: ${license_file}"
      else
        collect_warning "License file not found at ${FILEBOT_LICENSE_FILE} or ${config_license}"
      fi
    fi
  else
    # Look for any .psm files in config directory
    config_dir="${SCRIPT_DIR}/config"
    if [[ -d "${config_dir}" ]]; then
      # Use a temporary variable to avoid masking find's return value
      find_output=""
      if find_output=$(find "${config_dir}" -name "*.psm" -print0 2>/dev/null); then
        while IFS= read -r -d '' psm_file; do
          if [[ -f "${psm_file}" ]]; then
            license_file="${psm_file}"
            echo "Found license file in config directory: ${license_file}"
            break
          fi
        done <<<"${find_output}"
      fi
    fi
  fi

  if [[ -n "${license_file}" && -f "${license_file}" ]]; then
    echo "📄 Setting up FileBot license..."
    log "Setting up FileBot license from ${license_file}"

    # Create FileBot config directory for operator
    echo "Creating FileBot config directory for ${OPERATOR_USERNAME}..."
    sudo -p "[FileBot setup] Enter password to create FileBot config directory: " \
      -iu "${OPERATOR_USERNAME}" mkdir -p "${FILEBOT_CONFIG_DIR}"
    check_success "FileBot config directory creation"

    # Copy license file to operator's FileBot config directory
    license_filename="$(basename "${license_file}")"
    target_license="${FILEBOT_CONFIG_DIR}/${license_filename}"

    echo "Copying license file to ${target_license}..."
    sudo -p "[FileBot setup] Enter password to copy license file: " \
      cp "${license_file}" "${target_license}"
    sudo -p "[FileBot setup] Enter password to set license file ownership: " \
      chown "${OPERATOR_USERNAME}:staff" "${target_license}"
    check_success "License file copy and ownership"

    # Apply the license
    echo "Applying FileBot license for ${OPERATOR_USERNAME}..."
    log "Applying FileBot license for ${OPERATOR_USERNAME}"

    if sudo -p "[FileBot setup] Enter password to apply FileBot license: " \
      -iu "${OPERATOR_USERNAME}" filebot --license "${target_license}"; then
      check_success "FileBot license application"
      echo "✅ FileBot license applied successfully"
      log "FileBot license applied successfully"
    else
      collect_error "Failed to apply FileBot license"
    fi
  else
    collect_warning "No FileBot license file found - FileBot will run in evaluation mode"
    echo "⚠️ No license file found - FileBot will run with limited functionality"
    log "No FileBot license file found"
  fi

  set_section "FileBot Configuration"

  # Configure FileBot for media processing
  echo "🔧 Configuring FileBot for media processing..."
  log "Configuring FileBot preferences"

  # Set up media format templates and paths
  configure_filebot_preferences

  echo ""
  echo "🎬 FileBot setup completed!"
  echo ""
  echo "FileBot is now configured for:"
  echo "• Media processing from: ${FILEBOT_MEDIA_PATH}/Torrents/pending-move"
  echo "• Organized output to: ${FILEBOT_MEDIA_PATH}/{plex} format"
  echo "• Automatic subtitle downloads (if OpenSubtitles configured)"
  echo ""
  echo "Integration with transmission-setup.sh:"
  echo "• Transmission downloads to pending-move directory"
  echo "• FileBot can process completed downloads"
  echo ""
  if [[ -n "${license_file}" ]]; then
    echo "• Licensed version - full functionality available"
  else
    echo "• Evaluation mode - consider adding license file for full functionality"
  fi
  echo ""

  log "FileBot setup completed successfully"
}

# Function to configure FileBot preferences
configure_filebot_preferences() {
  log "Configuring FileBot preferences for operator"

  # Configure FileBot format templates
  echo "Setting up media format templates..."

  # Set the main rename format for episodes (TV shows)
  if sudo -p "[FileBot setup] Enter password to configure episode format: " \
    -iu "${OPERATOR_USERNAME}" \
    defaults write net.filebot.ui "/net/filebot/ui/rename/format.recent.episode/0" \
    -string "${FILEBOT_MEDIA_PATH}/{plex}"; then
    check_success "Episode format configuration"
  else
    collect_error "Failed to configure episode format"
  fi

  # Set the main rename format for movies
  if sudo -p "[FileBot setup] Enter password to configure movie format: " \
    -iu "${OPERATOR_USERNAME}" \
    defaults write net.filebot.ui "/net/filebot/ui/rename/format.recent.movie/0" \
    -string "${FILEBOT_MEDIA_PATH}/{plex}"; then
    check_success "Movie format configuration"
  else
    collect_error "Failed to configure movie format"
  fi

  # Set the current rename formats
  if sudo -p "[FileBot setup] Enter password to set current episode format: " \
    -iu "${OPERATOR_USERNAME}" \
    defaults write net.filebot.ui "/net/filebot/ui/rename/rename.format.episode" \
    -string "${FILEBOT_MEDIA_PATH}/{plex}"; then
    check_success "Current episode format configuration"
  else
    collect_error "Failed to configure current episode format"
  fi

  if sudo -p "[FileBot setup] Enter password to set current movie format: " \
    -iu "${OPERATOR_USERNAME}" \
    defaults write net.filebot.ui "/net/filebot/ui/rename/rename.format.movie" \
    -string "${FILEBOT_MEDIA_PATH}/{plex}"; then
    check_success "Current movie format configuration"
  else
    collect_error "Failed to configure current movie format"
  fi

  # Set the dialog open folder to the pending-move directory
  if sudo -p "[FileBot setup] Enter password to set default open folder: " \
    -iu "${OPERATOR_USERNAME}" \
    defaults write net.filebot.ui "/net/filebot/ui/dialog.open.folder" \
    -string "${FILEBOT_MEDIA_PATH}/Torrents/pending-move"; then
    check_success "Default open folder configuration"
  else
    collect_error "Failed to configure default open folder"
  fi

  # Configure rename actions (artwork, subtitles, etc.)
  if sudo -p "[FileBot setup] Enter password to configure rename actions: " \
    -iu "${OPERATOR_USERNAME}" \
    defaults write net.filebot.ui "/net/filebot/ui/rename/rename.action.apply" \
    -string "ARTWORK SRT SUBTITLES"; then
    check_success "Rename actions configuration"
  else
    collect_error "Failed to configure rename actions"
  fi

  # Set subtitle language to English
  if sudo -p "[FileBot setup] Enter password to configure subtitle language: " \
    -iu "${OPERATOR_USERNAME}" \
    defaults write net.filebot.ui "/net/filebot/ui/subtitle/language.selected" \
    -string "en"; then
    check_success "Subtitle language configuration"
  else
    collect_error "Failed to configure subtitle language"
  fi

  # Mark getting started as completed to skip intro
  if sudo -p "[FileBot setup] Enter password to skip getting started dialog: " \
    -iu "${OPERATOR_USERNAME}" \
    defaults write net.filebot.ui "/net/filebot/ui/getting.started" \
    -int 1; then
    check_success "Getting started dialog skip configuration"
  else
    collect_error "Failed to configure getting started dialog skip"
  fi

  echo "✅ FileBot preferences configured"
  log "FileBot preferences configured successfully"

  # Configure OpenSubtitles credentials if available
  configure_opensubtitles_login
}

# Function to configure OpenSubtitles login
configure_opensubtitles_login() {
  log "Configuring OpenSubtitles login for operator"

  # Try to retrieve OpenSubtitles credentials from login keychain
  echo "🔐 Configuring OpenSubtitles login..."

  # Ensure keychain is unlocked before accessing
  if ! security unlock-keychain -p "${ADMINISTRATOR_PASSWORD}" 2>/dev/null; then
    collect_error "Failed to unlock keychain for credential retrieval"
    return 1
  fi

  local opensubtitles_credentials
  if opensubtitles_credentials=$(security find-generic-password -s "opensubtitles-${HOSTNAME_LOWER}" -a "${HOSTNAME_LOWER}" -w 2>/dev/null); then
    echo "✅ Found OpenSubtitles credentials in keychain"
    log "Retrieved OpenSubtitles credentials from login keychain"

    # Split username:password format
    local opensubtitles_username opensubtitles_password
    opensubtitles_username="${opensubtitles_credentials%%:*}"
    opensubtitles_password="${opensubtitles_credentials#*:}"

    # Configure OpenSubtitles login in FileBot
    # Format: username<TAB>password
    local credentials_value="${opensubtitles_username}	${opensubtitles_password}"

    if sudo -p "[FileBot setup] Enter password to configure OpenSubtitles login: " \
      -iu "${OPERATOR_USERNAME}" \
      defaults write net.filebot.login "/net/filebot/login/OpenSubtitles" \
      -string "${credentials_value}"; then
      check_success "OpenSubtitles login configuration"
      echo "✅ OpenSubtitles login configured for automatic subtitle downloads"
      log "OpenSubtitles credentials configured successfully"
    else
      collect_error "Failed to configure OpenSubtitles login"
    fi

    # Clear credentials from memory
    unset opensubtitles_credentials opensubtitles_username opensubtitles_password credentials_value
  else
    collect_warning "OpenSubtitles credentials not found in keychain - skipping automatic login setup"
    echo "📝 Note: For subtitle downloads, configure OpenSubtitles credentials manually in FileBot"
    echo "   Or add OpenSubtitles credentials to 1Password configuration system"
    log "OpenSubtitles credentials not available - manual setup required"
  fi
}

# Run main function
main "$@"
