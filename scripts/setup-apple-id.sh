#!/usr/bin/env bash
#
# setup-apple-id.sh - Apple ID and iCloud configuration
#
# This script handles Apple ID authentication and configures iCloud services
# for the Mac Mini server. It includes:
# - Apple ID authentication with System Settings integration
# - iCloud services configuration (disables unnecessary services)
# - Notification settings for messaging applications
#
# Usage: ./setup-apple-id.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude
# Version: 1.0
# Created: 2025-09-05

# Exit on any error
set -euo pipefail

# Parse command line arguments
FORCE=false
for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "Usage: $0 [--force]"
      exit 1
      ;;
  esac
done

# Configuration loading with fallback to environment variable
if [[ -n "${SETUP_DIR:-}" ]]; then
  CONFIG_FILE="${SETUP_DIR}/config/config.conf"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SETUP_DIR="$(dirname "${SCRIPT_DIR}")"
  CONFIG_FILE="${SETUP_DIR}/config/config.conf"
fi

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "❌ Configuration file not found: ${CONFIG_FILE}"
  exit 1
fi

# Load shared functions
FUNCTIONS_FILE="${SETUP_DIR}/scripts/functions.sh"
if [[ -f "${FUNCTIONS_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${FUNCTIONS_FILE}"
else
  echo "❌ Functions file not found: ${FUNCTIONS_FILE}"
  exit 1
fi

# Configure Apple ID
section "Apple ID Configuration"

# Check if Apple ID is already configured
APPLE_ID_CONFIGURED=false
if defaults read ~/Library/Preferences/MobileMeAccounts.plist 2>/dev/null >/dev/null; then
  # Try to get the configured Apple ID from AccountID field
  CONFIGURED_APPLE_ID=$(plutil -extract Accounts.0.AccountID raw ~/Library/Preferences/MobileMeAccounts.plist 2>/dev/null || echo "")
  if [[ -n "${CONFIGURED_APPLE_ID}" ]]; then
    show_log "✅ Apple ID already configured: ${CONFIGURED_APPLE_ID}"
    APPLE_ID_CONFIGURED=true
  else
    # Fallback - just check if the plist exists and has accounts
    ACCOUNT_COUNT=$(plutil -extract Accounts raw ~/Library/Preferences/MobileMeAccounts.plist 2>/dev/null | grep -c "AccountID" || echo "0")
    if [[ "${ACCOUNT_COUNT}" -gt 0 ]]; then
      show_log "✅ Apple ID already configured"
      APPLE_ID_CONFIGURED=true
    fi
  fi
fi

# Only prompt for Apple ID setup if not already configured
if [[ "${APPLE_ID_CONFIGURED}" != true ]]; then
  # Open Apple ID one-time password link if available
  APPLE_ID_URL_FILE="${SETUP_DIR}/config/apple_id_password.url"
  if [[ -f "${APPLE_ID_URL_FILE}" ]]; then
    log "Opening Apple ID one-time password link"
    open "${APPLE_ID_URL_FILE}"
    check_success "Opening Apple ID password link"

    # Ask user to confirm they've retrieved the password
    if [[ "${FORCE}" = false ]]; then
      read -rp "Have you retrieved your Apple ID password? (Y/n) " -n 1 -r
      echo
      # Default to Yes if Enter pressed (empty REPLY)
      if [[ -n "${REPLY}" ]] && [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        show_log "Please retrieve your Apple ID password before continuing"
        open "${APPLE_ID_URL_FILE}"
        read -p "Press any key to continue once you have your password... " -n 1 -r
        echo
      fi
    fi
  else
    log "No Apple ID one-time password link found - you'll need to retrieve your password manually"
  fi

  # Open System Settings to the Apple ID section
  if [[ "${FORCE}" = false ]]; then
    show_log "Opening System Settings to the Apple ID section"
    show_log "IMPORTANT: You will need to complete several steps:"
    show_log "1. Enter your Apple ID and password"
    show_log "2. You may be prompted to enter your Mac's user password"
    show_log "3. Approve any verification codes that are sent to your other devices"
    show_log "4. Select which services to enable (you can customize these)"
    show_log "5. Return to Terminal after completing all Apple ID setup dialogs"

    open "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"
    check_success "Opening Apple ID settings"

    # Give user time to add their Apple ID
    read -rp "Please configure your Apple ID in System Settings. Press any key when done... " -n 1 -r
    echo

    # Close System Settings now that user is done with Apple ID configuration
    show_log "Closing System Settings..."
    osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true
  fi
fi

# Configure iCloud and notification settings for admin user (always run)
section "Configuring iCloud and Notification Settings"

# Disable specific iCloud services for admin user (server doesn't need these)
log "Disabling unnecessary iCloud services for admin user"
defaults write com.apple.bird syncedDataclasses -dict \
  "Bookmarks" 0 \
  "Calendar" 0 \
  "Contacts" 0 \
  "Mail" 0 \
  "Messages" 0 \
  "Notes" 0 \
  "Reminders" 0
check_success "iCloud services configuration"

# Disable notifications for messaging apps
log "Disabling notifications for messaging apps"
defaults write com.apple.ncprefs apps -array-add '{
    "bundle-id" = "com.apple.FaceTime";
    "flags" = 0;
}'
defaults write com.apple.ncprefs apps -array-add '{
    "bundle-id" = "com.apple.MobileSMS";
    "flags" = 0;
}'
defaults write com.apple.ncprefs apps -array-add '{
    "bundle-id" = "com.apple.iChat";
    "flags" = 0;
}'
check_success "Notification settings configuration"

show_log "✅ Apple ID and iCloud configuration completed"
