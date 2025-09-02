#!/usr/bin/env bash
#
# setup-system-preferences.sh - System preferences and configuration module
#
# This script configures macOS system preferences, security settings,
# power management, and user account preferences. It handles operator
# account configuration, automatic login, and various system defaults.
#
# Usage: ./setup-system-preferences.sh [--force] [--skip-update]
#   --force: Skip all confirmation prompts
#   --skip-update: Skip software updates
#
# Author: Claude (modularized from first-boot.sh)
# Version: 1.0
# Created: 2025-09-02

# Exit on any error
set -euo pipefail

# Parse command line arguments
FORCE=false
SKIP_UPDATE=true # Default to skip for consistency with first-boot.sh

for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    --skip-update)
      SKIP_UPDATE=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Set up logging
export LOG_DIR
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
current_hostname="$(hostname)"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${current_hostname}")"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# log function - only writes to log file
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

# show_log function - shows output to user and logs
show_log() {
  echo "$1"
  log "$1"
}

# section function - shows section header and logs
section() {
  show_log ""
  show_log "=== $1 ==="
}

# Error and warning collection functions for module context
# These write to temporary files shared with first-boot.sh
collect_error() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  # Append to shared temporary file (exported from first-boot.sh)
  if [[ -n "${SETUP_ERRORS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_ERRORS_FILE}"
  fi
}

collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "⚠️ ${clean_message}"
  # Append to shared temporary file (exported from first-boot.sh)
  if [[ -n "${SETUP_WARNINGS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_WARNINGS_FILE}"
  fi
}

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  show_log ""
  show_log "=== $1 ==="
}

# check_success function
check_success() {
  local operation_name="$1"
  local exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    log "✅ ${operation_name}"
  else
    if [[ "${FORCE}" == true ]]; then
      collect_warning "${operation_name} failed but continuing due to --force flag"
    else
      collect_error "${operation_name} failed"
      show_log "❌ ${operation_name} failed (exit code: ${exit_code})"
      read -p "Continue anyway? (y/N): " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Configuration variables
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"
SSH_KEY_SOURCE="${SETUP_DIR}/ssh_keys"

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  log "Loaded configuration from ${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  OPERATOR_USERNAME="operator"
fi

# Source the keychain credentials helper
# shellcheck source=/dev/null
if [[ -f "${SETUP_DIR}/first-boot.sh" ]]; then
  # Extract the get_keychain_credential function from first-boot.sh
  # Enhanced version for module context with automatic keychain unlocking
  get_keychain_credential() {
    local service="$1"
    local account="$2"

    # First attempt without unlocking
    local credential
    if credential=$(security find-generic-password -s "${service}" -a "${account}" -w 2>/dev/null); then
      echo "${credential}"
      return 0
    fi

    # If that failed, check if keychain is locked and unlock it
    if security show-keychain-info login.keychain 2>&1 | grep -q "locked"; then
      if [[ -n "${ADMINISTRATOR_PASSWORD:-}" ]]; then
        log "Admin keychain is locked - unlocking automatically with administrator password"
        if security unlock-keychain -p "${ADMINISTRATOR_PASSWORD}" login.keychain 2>/dev/null; then
          log "✅ Successfully unlocked admin keychain"
          # Retry credential retrieval after unlocking
          if credential=$(security find-generic-password -s "${service}" -a "${account}" -w 2>/dev/null); then
            echo "${credential}"
            return 0
          fi
        else
          collect_warning "Failed to unlock admin keychain with administrator password"
          return 1
        fi
      else
        collect_warning "Admin keychain is locked and administrator password not available in module context"
        return 1
      fi
    fi

    # Final attempt - may just not exist
    collect_error "Failed to retrieve credential from Keychain: ${service}"
    return 1
  }
fi

#
# SYSTEM PREFERENCES CONFIGURATION
#

# Only proceed if operator account is configured
if [[ -n "${OPERATOR_USERNAME:-}" ]]; then
  # Skip setup screens for operator account (more aggressive approach)
  log "Configuring operator account to skip setup screens"
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant DidSeeCloudSetup -bool true
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant SkipCloudSetup -bool true
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant DidSeePrivacy -bool true
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant GestureMovieSeen none
  PRODUCT_VERSION=$(sw_vers -productVersion)
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant LastSeenCloudProductVersion "${PRODUCT_VERSION}"
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.screensaver showClock -bool false

  # Screen Time and Apple Intelligence
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.ScreenTimeAgent DidCompleteSetup -bool true
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.intelligenceplatform.ui SetupHasBeenDisplayed -bool true

  # Accessibility and Data & Privacy
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant DidSeeDataAndPrivacy -bool true

  # TouchID setup bypass (this might help with the password confusion)
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.apple.SetupAssistant DidSeeTouchID -bool true
  check_success "Operator setup screen suppression"

  # Set up operator SSH keys if available
  if [[ -d "${SSH_KEY_SOURCE}" ]] && [[ -f "${SSH_KEY_SOURCE}/operator_authorized_keys" ]]; then
    OPERATOR_SSH_DIR="/Users/${OPERATOR_USERNAME}/.ssh"
    log "Setting up SSH keys for operator account"

    sudo -p "[SSH setup] Enter password to configure operator SSH keys: " mkdir -p "${OPERATOR_SSH_DIR}"
    sudo cp "${SSH_KEY_SOURCE}/operator_authorized_keys" "${OPERATOR_SSH_DIR}/authorized_keys"
    sudo chmod 700 "${OPERATOR_SSH_DIR}"
    sudo chmod 600 "${OPERATOR_SSH_DIR}/authorized_keys"
    sudo chown -R "${OPERATOR_USERNAME}" "${OPERATOR_SSH_DIR}"

    check_success "Operator SSH key setup"

    # Add operator to SSH access group
    log "Adding operator to SSH access group"
    sudo -p "[SSH setup] Enter password to add operator to SSH access group: " dseditgroup -o edit -a "${OPERATOR_USERNAME}" -t user com.apple.access_ssh
    check_success "Operator SSH group membership"
  fi

  # Configure Remote Management for operator user (now that account exists)
  log "Configuring Remote Management privileges for operator user"
  sudo -p "[Remote management] Enter password to configure operator privileges: " /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -configure -users "${OPERATOR_USERNAME}" \
    -access -on \
    -privs -all

  check_success "Operator Remote Management privileges"
  show_log "✅ Remote Management configured for operator user"
fi

# Fast User Switching
section "Enabling Fast User Switching"
log "Configuring Fast User Switching for multi-user access"
sudo -p "[System setup] Enter password to enable multiple user sessions: " defaults write /Library/Preferences/.GlobalPreferences MultipleSessionEnabled -bool true
check_success "Fast User Switching configuration"

# Fast User Switching menu bar style and visibility
defaults write .GlobalPreferences userMenuExtraStyle -int 1 # username
if [[ -n "${OPERATOR_USERNAME:-}" ]]; then
  sudo -p "[User setup] Enter password to configure operator menu style: " -iu "${OPERATOR_USERNAME}" defaults write .GlobalPreferences userMenuExtraStyle -int 1 # username
fi
defaults -currentHost write com.apple.controlcenter UserSwitcher -int 2 # menubar
if [[ -n "${OPERATOR_USERNAME:-}" ]]; then
  sudo -iu "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.controlcenter UserSwitcher -int 2 # menubar
fi

# Configure automatic login for operator account (if configured and keychain available)
if [[ -n "${OPERATOR_USERNAME:-}" ]] && [[ -f "${SETUP_DIR}/config/keychain_manifest.conf" ]]; then
  section "Automatic login for operator account"
  log "Configuring automatic login for operator account"

  # Load keychain manifest
  manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
  # shellcheck source=/dev/null
  source "${manifest_file}"

  # Get credential securely from admin Keychain for auto-login
  log "Retrieving operator password from admin keychain for automatic login setup"
  # shellcheck disable=SC2154 # KEYCHAIN_OPERATOR_SERVICE and KEYCHAIN_ACCOUNT loaded from sourced manifest
  if operator_password=$(get_keychain_credential "${KEYCHAIN_OPERATOR_SERVICE}" "${KEYCHAIN_ACCOUNT}"); then
    # Create the encoded password file that macOS uses for auto-login
    encoded_password=$(echo "${operator_password}" | openssl enc -base64)
    echo "${encoded_password}" | sudo -p "[Auto-login] Enter password to configure automatic login: " tee /etc/kcpassword >/dev/null
    sudo chmod 600 /etc/kcpassword
    check_success "Create auto-login password file"

    # Set the auto-login user
    sudo -p "[Auto-login] Enter password to set auto-login user: " defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "${OPERATOR_USERNAME}"
    check_success "Set auto-login user"

    # Clear passwords from memory immediately
    unset operator_password encoded_password

    # Comprehensive verification of auto-login configuration
    verify_autologin_configuration() {
      local verification_failed=false

      log "Performing comprehensive auto-login verification..."

      # Test 1: Auto-login user is correctly configured
      local auto_login_user
      auto_login_user=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo "")
      if [[ "${auto_login_user}" != "${OPERATOR_USERNAME}" ]]; then
        collect_error "Auto-login is not configured for operator account (current: ${auto_login_user:-none})"
        verification_failed=true
      else
        log "✓ Auto-login is configured for operator account"
      fi

      # Test 2: Auto-login password file exists
      if [[ ! -f "/etc/kcpassword" ]]; then
        collect_error "Auto-login password file missing (/etc/kcpassword)"
        verification_failed=true
      else
        local kcpassword_perms
        kcpassword_perms=$(stat -f "%Mp%Lp" /etc/kcpassword 2>/dev/null || echo "unknown")
        if [[ "${kcpassword_perms}" == "600" || "${kcpassword_perms}" == "0600" ]]; then
          log "✓ Auto-login password file exists with correct permissions"
        else
          collect_error "Auto-login password file has incorrect permissions: ${kcpassword_perms} (should be 600)"
          verification_failed=true
        fi
      fi

      # Test 3: FileVault compatibility check (if not already done)
      local filevault_status
      filevault_status=$(fdesetup status 2>/dev/null || echo "unknown")
      if [[ "${filevault_status}" == *"FileVault is On"* ]]; then
        collect_error "FileVault is enabled - this will prevent auto-login from working"
        verification_failed=true
      elif [[ "${filevault_status}" == *"FileVault is Off"* ]]; then
        log "✓ FileVault is disabled - auto-login compatibility confirmed"
      else
        collect_warning "FileVault status unclear for auto-login: ${filevault_status}"
      fi

      # Overall status
      if [[ "${verification_failed}" == "true" ]]; then
        collect_error "Auto-login configuration verification FAILED - operator may not auto-login"
        return 1
      else
        show_log "✅ Auto-login configuration verification PASSED"
        return 0
      fi
    }

    # Run auto-login verification
    if verify_autologin_configuration; then
      show_log "✅ Automatic login configured and verified for ${OPERATOR_USERNAME}"
    else
      collect_error "Auto-login configuration failed verification"
    fi
  else
    collect_warning "Failed to retrieve operator password from admin keychain - skipping automatic login setup"
    log "⚠️ Operator will need to log in manually on first boot"
  fi
fi

# Add operator to sudoers (if operator is configured)
if [[ -n "${OPERATOR_USERNAME:-}" ]]; then
  section "Configuring sudo access for operator"
  log "Adding operator account to sudoers"

  # Add operator to admin group for sudo access
  sudo -p "[Account setup] Enter password to add operator to admin group: " dseditgroup -o edit -a "${OPERATOR_USERNAME}" -t user admin
  check_success "Operator admin group membership"

  # Verify sudo access works for operator
  log "Verifying sudo access for operator"
  if sudo -p "[Account setup] Enter password to verify operator sudo access: " -u "${OPERATOR_USERNAME}" sudo -n true 2>/dev/null; then
    show_log "✅ Operator sudo access verified (passwordless test)"
  else
    # This is expected - they'll need to enter password for sudo
    show_log "✅ Operator has sudo access (will require password)"
  fi
fi

# Fix scroll setting
section "Fix scroll setting"
log "Fixing Apple's default scroll setting"
defaults write -g com.apple.swipescrolldirection -bool false
if [[ -n "${OPERATOR_USERNAME:-}" ]]; then
  sudo -p "[User setup] Enter password to configure operator scroll direction: " -iu "${OPERATOR_USERNAME}" defaults write -g com.apple.swipescrolldirection -bool false
fi
check_success "Fix scroll setting"

# Configure power management settings
section "Configuring Power Management"
log "Setting power management for server use"

# Check current settings
CURRENT_SLEEP=$(pmset -g 2>/dev/null | grep -E "^[ ]*sleep" | awk '{print $2}' || echo "unknown")
CURRENT_DISPLAYSLEEP=$(pmset -g 2>/dev/null | grep -E "^[ ]*displaysleep" | awk '{print $2}' || echo "unknown")
CURRENT_DISKSLEEP=$(pmset -g 2>/dev/null | grep -E "^[ ]*disksleep" | awk '{print $2}' || echo "unknown")
CURRENT_WOMP=$(pmset -g 2>/dev/null | grep -E "^[ ]*womp" | awk '{print $2}' || echo "unknown")
CURRENT_AUTORESTART=$(pmset -g 2>/dev/null | grep -E "^[ ]*autorestart" | awk '{print $2}' || echo "unknown")

# Apply settings only if they differ from current
if [[ "${CURRENT_SLEEP}" != "0" ]]; then
  sudo -p "[Power management] Enter password to disable system sleep: " pmset -a sleep 0
  log "Disabled system sleep"
fi

if [[ "${CURRENT_DISPLAYSLEEP}" != "60" ]]; then
  sudo -p "[Power management] Enter password to configure display sleep: " pmset -a displaysleep 60 # Display sleeps after 1 hour
  log "Set display sleep to 60 minutes"
fi

if [[ "${CURRENT_DISKSLEEP}" != "0" ]]; then
  sudo -p "[Power management] Enter password to disable disk sleep: " pmset -a disksleep 0
  log "Disabled disk sleep"
fi

if [[ "${CURRENT_WOMP}" != "1" ]]; then
  sudo -p "[Power management] Enter password to enable wake on network: " pmset -a womp 1 # Enable wake on network access
  log "Enabled Wake on Network Access"
fi

if [[ "${CURRENT_AUTORESTART}" != "1" ]]; then
  sudo -p "[Power management] Enter password to enable auto-restart: " pmset -a autorestart 1 # Restart on power failure
  log "Enabled automatic restart after power failure"
fi

check_success "Power management configuration"

# Configure screen saver password requirement
section "Configuring screen saver password requirement"
defaults -currentHost write com.apple.screensaver askForPassword -int 1
defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0
if [[ -n "${OPERATOR_USERNAME:-}" ]]; then
  sudo -p "[Security setup] Enter password to configure operator screen saver security: " -iu "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.screensaver askForPassword -int 1
  sudo -iu "${OPERATOR_USERNAME}" defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0
fi
log "Enabled immediate password requirement after screen saver"

# Run software updates if not skipped
if [[ "${SKIP_UPDATE}" == false ]]; then
  section "Running Software Updates"
  show_log "Checking for software updates (this may take a while)"

  # Check for updates
  UPDATE_CHECK=$(softwareupdate -l)
  if echo "${UPDATE_CHECK}" | grep -q "No new software available"; then
    log "System is up to date"
  else
    log "Installing software updates in background mode"
    sudo -p "[System update] Enter password to install software updates: " softwareupdate -i -a --background
    check_success "Initiating background software update"
  fi
else
  log "Skipping software updates as requested"
fi

# Configure firewall
section "Configuring Firewall"

# Ensure it's on
log "Ensuring firewall is enabled"
sudo -p "[Firewall setup] Enter password to enable application firewall: " /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on

# Add SSH to firewall allowed services
log "Ensuring SSH is allowed through firewall"
sudo -p "[Firewall setup] Enter password to configure SSH firewall access: " /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/sbin/sshd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/sbin/sshd

# Configure security settings
section "Configuring Security Settings"

# Disable automatic app downloads
defaults write com.apple.SoftwareUpdate AutomaticDownload -int 0
log "Disabled automatic app downloads"

show_log "✅ System preferences configuration completed successfully"
