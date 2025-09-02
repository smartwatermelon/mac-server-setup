#!/usr/bin/env bash
#
# first-boot.sh - Complete setup script for Mac Mini server
#
# This script performs the complete setup for the Mac Mini server after
# the macOS setup wizard has been completed. It configures:
# - Remote management (SSH and Remote Desktop)
# - User accounts
# - System settings
# - Power management
# - Security configurations
# - Homebrew and packages installation
# - Application preparation
#
# Usage: ./first-boot.sh [--force] [--skip-update] [--skip-homebrew] [--skip-packages]
#   --force: Skip all confirmation prompts
#   --skip-update: Skip software updates (which can be time-consuming)
#   --skip-homebrew: Skip Homebrew installation/update
#   --skip-packages: Skip package installation
#
# Author: Claude
# Version: 2.2
# Created: 2025-05-18

# Exit on any error
set -euo pipefail

# Configuration variables - adjust as needed
ADMIN_USERNAME=$(whoami)                                  # Set this once and use throughout
ADMINISTRATOR_PASSWORD=""                                 # Get it interactively later
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Directory where AirDropped files are located (script now at root)
SSH_KEY_SOURCE="${SETUP_DIR}/ssh_keys"
export FORMULAE_FILE="${SETUP_DIR}/config/formulae.txt"
export CASKS_FILE="${SETUP_DIR}/config/casks.txt"
RERUN_AFTER_FDA=false
export NEED_SYSTEMUI_RESTART=false
export NEED_CONTROLCENTER_RESTART=false
# Safety: Development machine fingerprint (to prevent accidental execution)
DEV_FINGERPRINT_FILE="${SETUP_DIR}/config/dev_fingerprint.conf"
DEV_MACHINE_FINGERPRINT=""             # Default blank - will be populated from file
export HOMEBREW_PREFIX="/opt/homebrew" # Apple Silicon

# Parse command line arguments
FORCE=false
SKIP_UPDATE=true # this is unreliable during setup
SKIP_HOMEBREW=false
SKIP_PACKAGES=false

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
    --skip-homebrew)
      SKIP_HOMEBREW=true
      shift
      ;;
    --skip-packages)
      SKIP_PACKAGES=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Load configuration
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  echo "Loaded configuration from ${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
  # Set fallback defaults
  SERVER_NAME="MACMINI"
  OPERATOR_USERNAME="operator"
  ONEPASSWORD_VAULT="personal"
  ONEPASSWORD_OPERATOR_ITEM="operator"
fi

# Set derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
OPERATOR_FULLNAME="${SERVER_NAME} Operator"

export LOG_DIR
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# _timeout function - uses timeout utility if installed, otherwise Perl
# https://gist.github.com/jaytaylor/6527607
function _timeout() {
  if command -v timeout; then
    timeout "$@"
  else
    if ! command -v perl; then
      echo "perl not found 😿"
      exit 1
    else
      perl -e 'alarm shift; exec @ARGV' "$@"
    fi
  fi
}

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

# New wrapper function - shows in main window AND logs
show_log() {
  local no_newline=false

  # Check for -n flag
  if [[ "$1" == "-n" ]]; then
    no_newline=true
    echo -n "$2"
    log -n "$2"
  else
    echo "$1"
    log "$1"
  fi
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Error and warning collection system using temporary files
# (Arrays cannot be exported to child processes in bash)
SETUP_ERRORS_FILE="/tmp/first-boot-setup-errors-$$"
SETUP_WARNINGS_FILE="/tmp/first-boot-setup-warnings-$$"
CURRENT_SCRIPT_SECTION=""

# Initialize temporary files
true >"${SETUP_ERRORS_FILE}"
true >"${SETUP_WARNINGS_FILE}"

# Export file paths and section for module access
export SETUP_ERRORS_FILE
export SETUP_WARNINGS_FILE
export CURRENT_SCRIPT_SECTION

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
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

  show_log "❌ ${clean_message}"
  # Append to temporary file for cross-process collection
  echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_ERRORS_FILE}"
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

  show_log "⚠️ ${clean_message}"
  # Append to temporary file for cross-process collection
  echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_WARNINGS_FILE}"
}

# Export error collection functions for module access
export -f collect_error
export -f collect_warning
export -f set_section

# Function to show collected errors and warnings at end
show_collected_issues() {
  # Count errors and warnings from temporary files
  local error_count=0
  local warning_count=0

  if [[ -f "${SETUP_ERRORS_FILE}" ]]; then
    error_count=$(wc -l <"${SETUP_ERRORS_FILE}" 2>/dev/null || echo "0")
  fi

  if [[ -f "${SETUP_WARNINGS_FILE}" ]]; then
    warning_count=$(wc -l <"${SETUP_WARNINGS_FILE}" 2>/dev/null || echo "0")
  fi

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    show_log "✅ Setup completed successfully with no errors or warnings!"
    # Clean up temporary files
    rm -f "${SETUP_ERRORS_FILE}" "${SETUP_WARNINGS_FILE}"
    return
  fi

  show_log ""
  show_log "====== SETUP SUMMARY ======"
  show_log "Setup completed, but ${error_count} errors and ${warning_count} warnings occurred:"
  show_log ""

  if [[ ${error_count} -gt 0 ]]; then
    show_log "ERRORS:"
    while IFS= read -r error; do
      show_log "  ${error}"
    done <"${SETUP_ERRORS_FILE}"
    show_log ""
  fi

  if [[ ${warning_count} -gt 0 ]]; then
    show_log "WARNINGS:"
    while IFS= read -r warning; do
      show_log "  ${warning}"
    done <"${SETUP_WARNINGS_FILE}"
    show_log ""
  fi

  show_log "Review the full log for details: ${LOG_FILE}"

  # Clean up temporary files
  rm -f "${SETUP_ERRORS_FILE}" "${SETUP_WARNINGS_FILE}"
}

# Function to check if a command was successful
check_success() {
  if [[ $? -eq 0 ]]; then
    show_log "✅ $1"
  else
    collect_error "$1 failed"
    if [[ "${FORCE}" == false ]]; then
      read -p "Continue anyway? (y/N) " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# SAFETY CHECK: Prevent execution on development machine
set_section "Development Machine Safety Check"

# Load development fingerprint if available
if [[ -f "${DEV_FINGERPRINT_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${DEV_FINGERPRINT_FILE}"
  log "Loaded development machine fingerprint for safety check"
else
  echo "❌ SAFETY ABORT: No development fingerprint file found"
  echo "This indicates the setup directory was not properly prepared with airdrop-prep.sh"
  exit 1
fi

# Abort if fingerprint is blank (safety default)
if [[ -z "${DEV_MACHINE_FINGERPRINT}" ]]; then
  echo "❌ SAFETY ABORT: Blank development machine fingerprint"
  echo "Setup directory appears corrupted or improperly prepared"
  exit 1
fi

# Check if running in a GUI session (required for many setup operations)
SESSION_TYPE=$(launchctl managername 2>/dev/null || echo "Unknown")
if [[ "${SESSION_TYPE}" != "Aqua" ]]; then
  echo "❌ ERROR: This script requires a GUI session to run properly"
  echo "Current session type: ${SESSION_TYPE}"
  echo ""
  echo "Mac Mini server setup requires desktop access for:"
  echo "- User account creation and configuration"
  echo "- System Settings modifications"
  echo "- AppleScript dialogs and automation"
  echo "- Application installations and setup"
  echo ""
  echo "Please run this script from the Mac's local desktop session."
  exit 1
fi
show_log "✓ GUI session detected (${SESSION_TYPE}) - setup can proceed"

# Get current machine fingerprint
CURRENT_FINGERPRINT=$(system_profiler SPHardwareDataType | grep "Hardware UUID" | awk '{print $3}')

# Abort if running on development machine
if [[ "${CURRENT_FINGERPRINT}" == "${DEV_MACHINE_FINGERPRINT}" ]]; then
  echo "❌ SAFETY ABORT: This script is running on the development machine"
  echo "Development fingerprint: ${DEV_MACHINE_FINGERPRINT}"
  echo "Current fingerprint: ${CURRENT_FINGERPRINT}"
  echo ""
  echo "This script is only for target Mac Mini server setup"
  exit 1
fi

show_log "✅ Safety check passed - not running on development machine"
log "Current machine: ${CURRENT_FINGERPRINT}"

# CRITICAL CHECK: FileVault compatibility for auto-login functionality
set_section "FileVault Compatibility Check"

log "Checking FileVault status (critical for auto-login functionality)..."

if ! command -v fdesetup >/dev/null 2>&1; then
  collect_warning "fdesetup not available, skipping FileVault check"
else
  filevault_status=$(fdesetup status 2>/dev/null || echo "unknown")

  if [[ "${filevault_status}" == *"FileVault is On"* ]]; then
    echo ""
    echo "=================================================================="
    echo "                    ⚠️  CRITICAL ISSUE DETECTED  ⚠️"
    echo "=================================================================="
    echo ""
    echo "FileVault disk encryption is ENABLED on this system."
    echo ""
    echo "This is incompatible with automatic login functionality,"
    echo "which is required for the operator account setup."
    echo ""
    echo "RESOLUTION OPTIONS:"
    echo "1. Try disabling FileVault via command line (fastest):"
    echo "   • Run: sudo fdesetup disable"
    echo "   • This requires decryption which may take several hours"
    echo "   • Then re-run this setup script"
    echo ""
    echo "2. Try disabling FileVault in System Settings:"
    echo "   • Open System Settings > Privacy & Security > FileVault"
    echo "   • Click 'Turn Off...' and follow the prompts"
    echo "   • This requires decryption which may take several hours"
    echo "   • Then re-run this setup script"
    echo ""
    echo "3. If FileVault cannot be disabled:"
    echo "   • Wipe this Mac completely and start over"
    echo "   • During macOS setup, DO NOT enable FileVault"
    echo "   • Ensure automatic login is enabled for admin account"
    echo ""
    echo "FileVault prevents automatic login for security reasons."
    echo "This Mac Mini server setup requires auto-login for the"
    echo "operator account to work properly."
    echo ""
    echo "=================================================================="
    echo ""

    collect_error "FileVault is enabled - incompatible with auto-login setup"

    if [[ "${FORCE}" != "true" ]]; then
      read -p "Would you like to disable FileVault now? (y/N): " -n 1 -r response
      echo
      case ${response} in
        [yY])
          show_log "Disabling FileVault - this may take 30-60+ minutes..."
          if sudo -p "[FileVault] Enter password to disable FileVault: " fdesetup disable; then
            show_log "✅ FileVault disabled successfully"
            show_log "Auto-login should now work properly"
          else
            collect_error "Failed to disable FileVault"
            show_log ""
            show_log "ALTERNATIVE OPTIONS (choose ONE):"
            show_log "1. System Settings > Privacy & Security > FileVault > Turn Off"
            show_log "2. Run 'sudo fdesetup disable' manually later"
            show_log "3. Perform clean system installation without FileVault"
          fi
          ;;
        *)
          show_log "FileVault remains enabled - setup will continue but auto-login may not work"
          collect_warning "User chose to continue with FileVault enabled"
          show_log ""
          show_log "ALTERNATIVE OPTIONS (choose ONE):"
          show_log "1. Disable via System Settings:"
          show_log "   • Open System Settings > Privacy & Security > FileVault"
          show_log "   • Click 'Turn Off...' and follow the prompts"
          show_log ""
          show_log "2. Disable via command line:"
          show_log "   • Run: sudo fdesetup disable"
          show_log ""
          show_log "3. If FileVault cannot be disabled:"
          show_log "   • Wipe this Mac completely and start over"
          show_log "   • During macOS setup, DO NOT enable FileVault"
          ;;
      esac
    else
      collect_warning "Force mode - continuing despite FileVault being enabled"
      show_log "Auto-login functionality will NOT work with FileVault enabled"
    fi

  elif [[ "${filevault_status}" == *"Deferred"* ]]; then
    echo ""
    echo "=================================================================="
    echo "                    ⚠️  POTENTIAL ISSUE DETECTED  ⚠️"
    echo "=================================================================="
    echo ""
    echo "FileVault has DEFERRED ENABLEMENT scheduled."
    echo "This means it will be enabled after the next reboot."
    echo ""
    echo "This will disable automatic login functionality required"
    echo "for the operator account."
    echo ""
    echo "RECOMMENDATION:"
    echo "Cancel FileVault enablement before it takes effect:"
    echo "  sudo fdesetup disable"
    echo ""
    echo "=================================================================="
    echo ""

    collect_warning "FileVault deferred enablement detected - will disable auto-login after reboot"

    if [[ "${FORCE}" != "true" ]]; then
      read -p "Continue with setup? (Y/n): " -n 1 -r response
      echo
      case ${response} in
        [nN])
          show_log "Setup cancelled to resolve FileVault deferred enablement"
          exit 1
          ;;
        *)
          show_log "Continuing setup - recommend disabling FileVault deferred enablement"
          ;;
      esac
    fi

  elif [[ "${filevault_status}" == *"FileVault is Off"* ]]; then
    show_log "✅ FileVault is disabled - automatic login will work properly"

  else
    collect_warning "FileVault status unclear: ${filevault_status}"
    show_log "Manual verification recommended for auto-login compatibility"
  fi
fi

# Create log file if it doesn't exist, rotate if it exists
if [[ -f "${LOG_FILE}" ]]; then
  # Rotate existing log file with timestamp
  ROTATED_LOG="${LOG_FILE%.log}-$(date +%Y%m%d-%H%M%S).log"
  mv "${LOG_FILE}" "${ROTATED_LOG}"
  log "Rotated previous log to: ${ROTATED_LOG}"
fi

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

# Function to check if a Terminal window with specific title exists
check_terminal_window_exists() {
  local window_title="$1"
  osascript -e "
    tell application \"Terminal\"
      set window_exists to false
      try
        repeat with w in windows
          if (name of w) contains \"${window_title}\" then
            set window_exists to true
            exit repeat
          end if
        end repeat
      end try
      return window_exists
    end tell
  " 2>/dev/null
}

# Tail log in separate window (only if one doesn't already exist)
window_exists=$(check_terminal_window_exists "Setup Log")
if [[ "${window_exists}" == "true" ]]; then
  log "Found existing Setup Log window - reusing it"
else
  log "Opening new Setup Log window"
  osascript -e 'tell application "Terminal" to do script "printf \"\\e]0;Setup Log\\a\"; tail -F '"${LOG_FILE}"'"' || echo "oops, no tail"
fi

# Print header
set_section "Starting Mac Mini '${SERVER_NAME}' Server Setup"
log "Running as user: ${ADMIN_USERNAME}"
timestamp="$(date)"
log "Date: ${timestamp}"
productversion="$(sw_vers -productVersion)"
log "macOS Version: ${productversion}"
log "Setup directory: ${SETUP_DIR}"

# Look for evidence we're being re-run after FDA grant
if [[ -f "/tmp/${HOSTNAME_LOWER}_fda_requested" ]]; then
  RERUN_AFTER_FDA=true
  rm -f "/tmp/${HOSTNAME_LOWER}_fda_requested"
  log "Detected re-run after Full Disk Access grant"
fi

# Confirm operation if not forced
if [[ "${FORCE}" == false ]] && [[ "${RERUN_AFTER_FDA}" == false ]]; then
  read -p "This script will configure your Mac Mini server. Continue? (Y/n) " -n 1 -r
  echo
  # Default to Yes if Enter pressed (empty REPLY)
  if [[ -n "${REPLY}" ]] && [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

# Collect administrator password for keychain operations
if [[ "${FORCE}" != "true" && "${RERUN_AFTER_FDA}" != "true" ]]; then
  echo
  echo "This script will need your Mac account password for keychain operations."
  read -r -e -p "Enter your Mac ${ADMIN_USERNAME} account password: " -s ADMINISTRATOR_PASSWORD
  echo # Add newline after hidden input

  # Validate password by testing with dscl
  until _timeout 1 dscl /Local/Default -authonly "${USER}" "${ADMINISTRATOR_PASSWORD}" &>/dev/null; do
    echo "Invalid ${ADMIN_USERNAME} account password. Try again or ctrl-C to exit."
    read -r -e -p "Enter your Mac ${ADMIN_USERNAME} account password: " -s ADMINISTRATOR_PASSWORD
    echo # Add newline after hidden input
  done

  show_log "✅ Administrator password validated"
  # Export for module access to keychain operations
  export ADMINISTRATOR_PASSWORD
else
  log "🆗 Skipping password prompt (force mode or FDA re-run)"
fi

#
# SYSTEM CONFIGURATION
#

# TouchID sudo setup - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-touchid-sudo.sh" --force
else
  "${SETUP_DIR}/scripts/setup-touchid-sudo.sh"
fi

# Configure sudo timeout to reduce password prompts during setup
section "Configuring sudo timeout"
show_log "Setting sudo timeout to 30 minutes for smoother setup experience"
sudo -p "[System setup] Enter password to configure sudo timeout: " tee /etc/sudoers.d/10_setup_timeout >/dev/null <<EOF
# Temporary sudo timeout extension for setup - 30 minutes
Defaults timestamp_timeout=30
EOF
# Fix permissions for sudoers file
sudo chmod 0440 /etc/sudoers.d/10_setup_timeout
check_success "Sudo timeout configuration"

# WiFi Network Assessment and Configuration - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-network.sh" --force
else
  "${SETUP_DIR}/scripts/setup-network.sh"
fi

# Set hostname and HD name - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-system-identity.sh" --force
else
  "${SETUP_DIR}/scripts/setup-system-identity.sh"
fi

# Setup SSH access
set_section "Configuring SSH Access"

# 1. Check if remote login is already enabled
if sudo -p "[SSH check] Enter password to check SSH status: " systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
  log "SSH is already enabled"
else
  # 2. Try to enable it directly first
  log "Attempting to enable SSH..."
  if sudo -p "[SSH setup] Enter password to enable SSH access: " systemsetup -setremotelogin on; then
    # 3.a Success case - it worked directly
    show_log "✅ SSH has been enabled successfully"
  else
    # 3.b Failure case - need FDA
    # Create a marker file to detect re-run
    touch "/tmp/${HOSTNAME_LOWER}_fda_requested"
    show_log "We need to grant Full Disk Access permissions to Terminal to enable SSH."
    show_log "1. We'll open System Settings to the Full Disk Access section"
    show_log "2. We'll open Finder showing Terminal.app"
    show_log "3. You'll need to drag Terminal from Finder into the FDA list"
    show_log "4. IMPORTANT: After adding Terminal, you must CLOSE this Terminal window"
    show_log "5. Then open a NEW Terminal window and run this script again"

    # Open Finder to show Terminal app
    log "Opening Finder window to locate Terminal.app..."
    osascript <<EOF
tell application "Finder"
  activate
  open folder "Applications:Utilities:" of startup disk
  select file "Terminal.app" of folder "Utilities" of folder "Applications" of startup disk
end tell
EOF

    # Open FDA preferences
    log "Opening System Settings to the Full Disk Access section..."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    show_log "After granting Full Disk Access to Terminal, close this window and run the script again."
    exit 0
  fi
fi

# Copy SSH keys if available
if [[ -d "${SSH_KEY_SOURCE}" ]]; then
  log "Found SSH keys at ${SSH_KEY_SOURCE}"

  # Set up admin SSH keys
  ADMIN_SSH_DIR="/Users/${ADMIN_USERNAME}/.ssh"
  if [[ ! -d "${ADMIN_SSH_DIR}" ]]; then
    log "Creating SSH directory for admin user"
    mkdir -p "${ADMIN_SSH_DIR}"
    chmod 700 "${ADMIN_SSH_DIR}"
  fi

  if [[ -f "${SSH_KEY_SOURCE}/authorized_keys" ]]; then
    log "Copying authorized_keys for admin user"
    cp "${SSH_KEY_SOURCE}/authorized_keys" "${ADMIN_SSH_DIR}/"
    chmod 600 "${ADMIN_SSH_DIR}/authorized_keys"
    check_success "Admin authorized_keys setup"
  fi

  # Copy SSH key pair for outbound connections
  if [[ -f "${SSH_KEY_SOURCE}/id_ed25519.pub" ]]; then
    log "Copying SSH public key for admin user"
    cp "${SSH_KEY_SOURCE}/id_ed25519.pub" "${ADMIN_SSH_DIR}/"
    chmod 644 "${ADMIN_SSH_DIR}/id_ed25519.pub"
    check_success "Admin SSH public key setup"
  fi

  if [[ -f "${SSH_KEY_SOURCE}/id_ed25519" ]]; then
    log "Copying SSH private key for admin user"
    cp "${SSH_KEY_SOURCE}/id_ed25519" "${ADMIN_SSH_DIR}/"
    chmod 600 "${ADMIN_SSH_DIR}/id_ed25519"
    check_success "Admin SSH private key setup"
  fi
else
  log "No SSH keys found at ${SSH_KEY_SOURCE} - manual key setup will be required"
fi

# Configure Remote Desktop (Screen Sharing and Remote Management)
section "Configuring Remote Desktop"

log "Remote Desktop requires GUI interaction to enable services, then automated permission setup"

# Run the user-guided setup script with proper verification
if [[ "${FORCE}" == "true" ]]; then
  log "Running Remote Desktop setup with --force flag"
  if "${SETUP_DIR}/scripts/setup-remote-desktop.sh" --force; then
    log "✅ Remote Desktop setup completed successfully with verification"
  else
    collect_error "Remote Desktop setup failed verification - Screen Sharing may not be working"
    log "Manual setup required: ${SETUP_DIR}/scripts/setup-remote-desktop.sh"
    log "Check System Settings > General > Sharing to enable Screen Sharing manually"
  fi
else
  log "Remote Desktop setup will automatically configure System Settings"
  if "${SETUP_DIR}/scripts/setup-remote-desktop.sh"; then
    log "✅ Remote Desktop setup completed successfully with verification"
  else
    collect_error "Remote Desktop setup failed verification - Screen Sharing may not be working"
    log "Manual setup required: ${SETUP_DIR}/scripts/setup-remote-desktop.sh"
    log "Check System Settings > General > Sharing to enable Screen Sharing manually"
  fi
fi

# After GUI setup, configure automated permissions for admin user
log "Configuring Remote Management privileges for admin user"
sudo -p "[Remote management] Enter password to configure admin privileges: " /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -users "${ADMIN_USERNAME}" \
  -access -on \
  -privs -all 2>/dev/null || {
  log "Note: Admin Remote Management privileges will be configured after services are enabled"
}
check_success "Admin Remote Management privileges (if services enabled)"

log "Note: Operator user privileges will be configured after account creation"

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
    if [[ "${FORCE}" == false ]]; then
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
  if [[ "${FORCE}" == false ]]; then
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

# Keychain credential management functions
# Secure credential retrieval function
get_keychain_credential() {
  local service="$1"
  local account="$2"

  local credential
  if credential=$(security find-generic-password \
    -s "${service}" \
    -a "${account}" \
    -w 2>/dev/null); then
    echo "${credential}"
    return 0
  else
    collect_error "Failed to retrieve credential from Keychain: ${service}"
    return 1
  fi
}

# Import credentials from external keychain and populate user keychains
import_external_keychain_credentials() {

  set_section "Importing Credentials from External Keychain"
  # Load keychain manifest
  local manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
  if [[ ! -f "${manifest_file}" ]]; then
    collect_error "Keychain manifest not found: ${manifest_file}"
    return 1
  fi

  # shellcheck source=/dev/null
  source "${manifest_file}"

  # Validate required variables from manifest
  if [[ -z "${KEYCHAIN_PASSWORD:-}" || -z "${EXTERNAL_KEYCHAIN:-}" ]]; then
    collect_error "Required keychain variables not found in manifest"
    return 1
  fi

  # Copy external keychain file to user's keychain directory (preserve original for idempotency)
  local external_keychain_file="${SETUP_DIR}/config/${EXTERNAL_KEYCHAIN}-db"
  local user_keychain_file="${HOME}/Library/Keychains/${EXTERNAL_KEYCHAIN}-db"

  if [[ ! -f "${external_keychain_file}" ]]; then
    if [[ -f "${user_keychain_file}" ]]; then
      log "External keychain file not found in setup package, but located in local keychains."
      cp "${user_keychain_file}" "${external_keychain_file}"
    else
      collect_error "External keychain file not found: ${external_keychain_file}"
      return 1
    fi
  fi

  log "Copying external keychain to user's keychain directory..."
  cp "${external_keychain_file}" "${user_keychain_file}"
  chmod 600 "${user_keychain_file}"
  check_success "External keychain file copied"

  # Unlock external keychain
  log "Unlocking external keychain with dev machine fingerprint..."
  if security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${EXTERNAL_KEYCHAIN}"; then
    show_log "✅ External keychain unlocked successfully"
  else
    collect_error "Failed to unlock external keychain"
    return 1
  fi

  # Import administrator credentials to default keychain
  log "Importing administrator credentials to default keychain..."

  # Unlock admin keychain first
  show_log "Unlocking administrator keychain for credential import..."

  if ! security unlock-keychain -p "${ADMINISTRATOR_PASSWORD}"; then
    collect_error "Failed to unlock administrator keychain"
    return 1
  fi

  # Import operator credential
  # shellcheck disable=SC2154 # KEYCHAIN_OPERATOR_SERVICE loaded from sourced manifest
  if operator_password=$(security find-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    # Store in default keychain
    security delete-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${operator_password}" -D "Mac Server Setup - Operator Account Password" -A -U; then
      # Verify storage
      if compare_password=$(security find-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w 2>/dev/null); then
        if [[ "${operator_password}" == "${compare_password}" ]]; then
          show_log "✅ Operator credential imported to administrator keychain"
        else
          collect_error "Operator credential verification failed after import"
          return 1
        fi
      else
        collect_error "Operator credential import verification failed"
        return 1
      fi
    else
      collect_error "Failed to import operator credential to administrator keychain"
      return 1
    fi
    unset operator_password compare_password
  else
    collect_error "Failed to retrieve operator credential from external keychain"
    return 1
  fi

  # Import Plex NAS credential
  # shellcheck disable=SC2154 # KEYCHAIN_PLEX_NAS_SERVICE loaded from sourced manifest
  if plex_nas_credential=$(security find-generic-password -s "${KEYCHAIN_PLEX_NAS_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_PLEX_NAS_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_PLEX_NAS_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${plex_nas_credential}" -D "Mac Server Setup - Plex NAS Credentials" -A -U; then
      show_log "✅ Plex NAS credential imported to administrator keychain"
    else
      collect_error "Failed to import Plex NAS credential to administrator keychain"
      return 1
    fi
    unset plex_nas_credential
  else
    collect_warning "Plex NAS credential not found in external keychain (may be optional)"
  fi

  # Import TimeMachine credential (optional)
  # shellcheck disable=SC2154 # KEYCHAIN_TIMEMACHINE_SERVICE loaded from sourced manifest
  if timemachine_credential=$(security find-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${timemachine_credential}" -D "Mac Server Setup - TimeMachine Credentials" -A -U; then
      show_log "✅ TimeMachine credential imported to administrator keychain"
    else
      collect_warning "Failed to import TimeMachine credential to administrator keychain"
    fi
    unset timemachine_credential
  else
    show_log "⚠️ TimeMachine credential not found in external keychain (optional)"
  fi

  # Import WiFi credential (optional)
  # shellcheck disable=SC2154 # KEYCHAIN_WIFI_SERVICE loaded from sourced manifest
  if wifi_credential=$(security find-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${EXTERNAL_KEYCHAIN}" 2>/dev/null); then
    security delete-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" &>/dev/null || true
    if security add-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w "${wifi_credential}" -D "Mac Server Setup - WiFi Credentials" -A -U; then
      show_log "✅ WiFi credential imported to administrator keychain"
    else
      collect_warning "Failed to import WiFi credential to administrator keychain"
    fi
    unset wifi_credential
  else
    show_log "⚠️ WiFi credential not found in external keychain (optional)"
  fi

  return 0
}

# Import credentials from external keychain
if ! import_external_keychain_credentials; then
  collect_error "External keychain credential import failed"
  exit 1
fi

# Create operator account if it doesn't exist
set_section "Setting Up Operator Account"
if dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
  log "Operator account already exists"
else
  log "Creating operator account"

  # Load keychain manifest
  manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
  # shellcheck source=/dev/null
  source "${manifest_file}"

  # Get credential securely from Keychain
  if operator_password=$(get_keychain_credential "${KEYCHAIN_OPERATOR_SERVICE}" "${KEYCHAIN_ACCOUNT}"); then
    log "Using password from Keychain (${ONEPASSWORD_OPERATOR_ITEM})"
  else
    log "❌ Failed to retrieve operator password from Keychain"
    exit 1
  fi

  # Create the operator account
  sudo -p "[Account setup] Enter password to create operator account: " sysadminctl -addUser "${OPERATOR_USERNAME}" -fullName "${OPERATOR_FULLNAME}" -password "${operator_password}" -hint "See 1Password ${ONEPASSWORD_OPERATOR_ITEM} for password" 2>/dev/null
  check_success "Operator account creation"

  # Comprehensive verification of operator account creation
  verify_operator_account_creation() {
    local verification_failed=false

    log "Performing comprehensive operator account verification..."

    # Test 1: Account exists in directory services
    if ! dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
      collect_error "Operator account does not exist in directory services"
      verification_failed=true
    else
      log "✓ Operator account exists in directory services"
    fi

    # Test 2: Password authentication works
    if ! dscl /Local/Default -authonly "${OPERATOR_USERNAME}" "${operator_password}" 2>/dev/null; then
      collect_error "Operator account password authentication failed"
      verification_failed=true
    else
      log "✓ Operator account password authentication successful"
    fi

    # Test 3: Home directory exists and is accessible
    local home_dir="/Users/${OPERATOR_USERNAME}"
    if [[ ! -d "${home_dir}" ]]; then
      collect_error "Operator home directory does not exist: ${home_dir}"
      verification_failed=true
    else
      # Check ownership using stat
      local owner_info
      owner_info=$(stat -f "%Su:%Sg" "${home_dir}" 2>/dev/null || echo "unknown:unknown")
      if [[ "${owner_info}" == "${OPERATOR_USERNAME}:staff" ]]; then
        log "✓ Operator home directory exists with correct ownership"
      else
        collect_warning "Operator home directory ownership may be incorrect: ${owner_info}"
      fi
    fi

    # Overall status
    if [[ "${verification_failed}" == "true" ]]; then
      collect_error "Operator account creation verification FAILED"
      return 1
    else
      show_log "✅ Operator account creation verification PASSED"
      return 0
    fi
  }

  # Run the verification
  if ! verify_operator_account_creation; then
    unset operator_password
    exit 1
  fi

  # Store reference to 1Password (don't store actual password)
  echo "Operator account password is stored in 1Password: op://${ONEPASSWORD_VAULT}/${ONEPASSWORD_OPERATOR_ITEM}/password" >"/Users/${ADMIN_USERNAME}/Documents/operator_password_reference.txt"
  chmod 600 "/Users/${ADMIN_USERNAME}/Documents/operator_password_reference.txt"

  show_log "Operator account created successfully"

  # Note: Operator keychain population no longer needed
  # SMB credentials are now embedded directly in mount scripts during plex-setup.sh
  # This eliminates the need to unlock operator keychain before first login
  log "✅ Operator keychain operations skipped - credentials embedded in service scripts"

  # Clear password from memory since we don't need it for keychain operations
  unset operator_password
fi

# HOMEBREW & PACKAGE INSTALLATION - delegated to module
#

# Homebrew and package installation - delegated to module
if [[ "${SKIP_HOMEBREW}" == true ]]; then
  set_hb_flag="--skip-homebrew"
else
  set_hb_flag=""
fi
if [[ "${SKIP_PACKAGES}" == true ]]; then
  set_package_flag="--skip-homebrew"
else
  set_package_flag=""
fi
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-homebrew-packages.sh" --force "${set_hb_flag}" "${set_package_flag}"
else
  "${SETUP_DIR}/scripts/setup-homebrew-packages.sh" "${set_hb_flag}" "${set_package_flag}"
fi

# SYSTEM PREFERENCES CONFIGURATION - delegated to module
#

# System preferences configuration - delegated to module
if [[ "${SKIP_UPDATE}" == true ]]; then
  set_update_flag="--skip-update"
else
  set_update_flag=""
fi
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-system-preferences.sh" --force "${set_update_flag}"
else
  "${SETUP_DIR}/scripts/setup-system-preferences.sh" "${set_update_flag}"
fi

# ADMIN ENVIRONMENT SETUP - delegated to module
#

# Admin environment setup - delegated to module
if [[ "${FORCE}" == true ]]; then
  "${SETUP_DIR}/scripts/setup-admin-environment.sh" --force
else
  "${SETUP_DIR}/scripts/setup-admin-environment.sh"
fi

# FINAL CLEANUP
#

# Clean up external keychain from setup directory (only after successful completion)
if [[ -n "${EXTERNAL_KEYCHAIN:-}" ]]; then
  setup_keychain_file="${SETUP_DIR}/config/${EXTERNAL_KEYCHAIN}-db"
  if [[ -f "${setup_keychain_file}" ]]; then
    log "Cleaning up external keychain from setup directory"
    rm -f "${setup_keychain_file}"
    log "✅ Setup keychain file cleaned up"
  fi
fi

# Clean up administrator password from memory
if [[ -n "${ADMINISTRATOR_PASSWORD:-}" ]]; then
  unset ADMINISTRATOR_PASSWORD
  log "✅ Administrator password cleared from memory"
fi

# Show collected errors and warnings
show_collected_issues

exit 0
