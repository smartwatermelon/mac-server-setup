#!/bin/bash
#
# first-boot.sh - Complete setup script for Mac Mini M2 'TILSIT' server
#
# This script performs the complete setup for the Mac Mini server after
# the macOS setup wizard has been completed. It configures:
# - Remote management (SSH)
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
# Version: 2.1
# Created: 2025-05-18

# Exit on any error
set -e

# Configuration variables - adjust as needed
HOSTNAME="TILSIT"; HOSTNAME_LOWER="$( tr '[:upper:]' '[:lower:]' <<< $HOSTNAME)"
OPERATOR_USERNAME="operator"
OPERATOR_FULLNAME="$HOSTNAME Operator"
ADMIN_USERNAME=$(whoami)  # Set this once and use throughout
export LOG_DIR; LOG_DIR="$HOME/.local/state" # XDG_STATE_HOME
LOG_FILE="$LOG_DIR/$HOSTNAME_LOWER-setup.log"
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # Directory where AirDropped files are located
SSH_KEY_SOURCE="$SETUP_DIR/ssh_keys"
PAM_D_SOURCE="$SETUP_DIR/pam.d"
WIFI_CONFIG_FILE="$SETUP_DIR/wifi/network.conf"
FORMULAE_FILE="/Users/$ADMIN_USERNAME/formulae.txt"
CASKS_FILE="/Users/$ADMIN_USERNAME/casks.txt"
RERUN_AFTER_FDA=false

# Parse command line arguments
FORCE=false
SKIP_UPDATE=false
SKIP_HOMEBREW=false
SKIP_PACKAGES=false

for arg in "$@"; do
  case $arg in
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

# Function to log messages to both console and log file
log() {
  mkdir -p "$LOG_DIR"
  local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $1"
  echo "[$timestamp] $1" | tee -a "$LOG_FILE" >/dev/null
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Function to check if a command was successful
check_success() {
  if [ $? -eq 0 ]; then
    log "✅ $1"
  else
    log "❌ $1 failed"
    if [ "$FORCE" = false ]; then
      read -p "Continue anyway? (y/n) " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"
fi

# Print header
section "Starting Mac Mini M2 '$HOSTNAME' Server Setup"
log "Running as user: $ADMIN_USERNAME"
log "Date: $(date)"
log "macOS Version: $(sw_vers -productVersion)"
log "Setup directory: $SETUP_DIR"

# Look for evidence we're being re-run after FDA grant
if [ -f "/tmp/${HOSTNAME_LOWER}_fda_requested" ]; then
    RERUN_AFTER_FDA=true
    rm -f "/tmp/${HOSTNAME_LOWER}_fda_requested"
    log "Detected re-run after Full Disk Access grant"
fi

# Confirm operation if not forced
if [ "$FORCE" = false ] && [ "$RERUN_AFTER_FDA" = false ]; then
  read -p "This script will configure your Mac Mini server. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

#
# SYSTEM CONFIGURATION
#

# Fix scroll setting
section "Fix scroll setting"
log "Fixing Apple's default scroll setting"
defaults write -g com.apple.swipescrolldirection -bool false
check_success "Fix scroll setting"

# TouchID sudo setup
section "TouchID sudo setup"
if [ -d "$PAM_D_SOURCE" ]; then
  log "Found TouchID sudo setup in $PAM_D_SOURCE"

  if [ -f "$PAM_D_SOURCE/sudo_local" ]; then
    # Check if the file already exists with the correct content
    if [ -f "/etc/pam.d/sudo_local" ] && diff -q "$PAM_D_SOURCE/sudo_local" "/etc/pam.d/sudo_local" >/dev/null; then
      log "TouchID sudo is already properly configured"
    else
      # File doesn't exist OR exists but has different content - same action either way
      log "TouchID sudo needs to be configured. We will ask for your user password."
      sudo cp "$PAM_D_SOURCE/sudo_local" "/etc/pam.d"
      check_success "TouchID sudo configuration"

      # Test TouchID configuration
      log "Testing TouchID sudo configuration..."
      sudo -k; sudo -v
      check_success "TouchID sudo test"
    fi
  else
    log "No sudo_local file found in $PAM_D_SOURCE"
  fi
else
  log "No TouchID sudo setup directory found at $PAM_D_SOURCE"
fi

# Configure WiFi if network config is available
section "Configuring WiFi Network"
if [ -f "$WIFI_CONFIG_FILE" ]; then
  log "Found WiFi configuration file"

  # Source the WiFi configuration file to get SSID and password
  # shellcheck source=/dev/null
  source "$WIFI_CONFIG_FILE"

  if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASSWORD" ]; then
    log "Configuring WiFi network: $WIFI_SSID"

    # Add WiFi network to preferred networks
    WIFI_IFACE="$(system_profiler SPAirPortDataType -xml | /usr/libexec/PlistBuddy -c "Print :0:_items:0:spairport_airport_interfaces:0:_name" /dev/stdin <<< "$(cat)")"
    networksetup -addpreferredwirelessnetworkatindex "$WIFI_IFACE" "$WIFI_SSID" "@" "WPA/WPA2"
    check_success "Add preferred WiFi network"
    security add-generic-password -D "AirPort network password" -a "$WIFI_SSID" -s "AirPort" -w "$WIFI_PASSWORD" || true
    check_success "Store password in keychain"
    log "Attempting to join WiFi network $WIFI_SSID. This may initially fail in some circumstances but the network will be automatically joined after reboot."
    networksetup -setairportnetwork "$WIFI_IFACE" "$WIFI_SSID" || true
    check_success "WiFi network configuration"

    # Securely remove the WiFi password from the configuration file
    sed -i '' "s/WIFI_PASSWORD=.*/WIFI_PASSWORD=\"REMOVED\"/" "$WIFI_CONFIG_FILE"
    log "WiFi password removed from configuration file for security"
  else
    log "WiFi configuration file does not contain valid SSID and password"
  fi
else
  log "No WiFi configuration file found - skipping WiFi setup"
fi

# Set hostname and HD name
section "Setting Hostname and HD volume name"
if [ "$(hostname)" = "$HOSTNAME" ]; then
  log "Hostname is already set to $HOSTNAME"
else
  log "Setting hostname to $HOSTNAME"
  sudo scutil --set ComputerName "$HOSTNAME"
  sudo scutil --set LocalHostName "$HOSTNAME"
  sudo scutil --set HostName "$HOSTNAME"
  check_success "Hostname configuration"
fi
log "Renaming HD"
diskutil rename "/Volumes/$(diskutil info -plist / | /usr/libexec/PlistBuddy -c "Print :VolumeName" /dev/stdin <<< "$(cat)")" "$HOSTNAME"
check_success "Renamed HD"

# Setup SSH access
section "Configuring SSH Access"

# 1. Check if remote login is already enabled
if sudo systemsetup -getremotelogin | grep -q "On"; then
  log "SSH is already enabled"
else
  # 2. Try to enable it directly first
  log "Attempting to enable SSH..."
  if sudo systemsetup -setremotelogin on; then
    # 3.a Success case - it worked directly
    log "✅ SSH has been enabled successfully"
  else
    # 3.b Failure case - need FDA
    # Create a marker file to detect re-run
    touch "/tmp/${HOSTNAME_LOWER}_fda_requested"
    log "We need to grant Full Disk Access permissions to Terminal to enable SSH."
    log "1. We'll open System Settings to the Full Disk Access section"
    log "2. We'll open Finder showing Terminal.app"
    log "3. You'll need to drag Terminal from Finder into the FDA list"
    log "4. IMPORTANT: After adding Terminal, you must CLOSE this Terminal window"
    log "5. Then open a NEW Terminal window and run this script again"

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

    log "After granting Full Disk Access to Terminal, close this window and run the script again."
    exit 0
  fi
fi

# Copy SSH keys if available
if [ -d "$SSH_KEY_SOURCE" ]; then
  log "Found SSH keys at $SSH_KEY_SOURCE"

  # Set up admin SSH keys
  ADMIN_SSH_DIR="/Users/$ADMIN_USERNAME/.ssh"
  if [ ! -d "$ADMIN_SSH_DIR" ]; then
    log "Creating SSH directory for admin user"
    mkdir -p "$ADMIN_SSH_DIR"
    chmod 700 "$ADMIN_SSH_DIR"
  fi

  if [ -f "$SSH_KEY_SOURCE/authorized_keys" ]; then
    log "Copying authorized_keys for admin user"
    cp "$SSH_KEY_SOURCE/authorized_keys" "$ADMIN_SSH_DIR/"
    chmod 600 "$ADMIN_SSH_DIR/authorized_keys"
    check_success "Admin SSH key setup"
  fi
else
  log "No SSH keys found at $SSH_KEY_SOURCE - manual key setup will be required"
fi

# Configure Apple ID (requires manual intervention)
# Open Apple ID one-time password link if available
APPLE_ID_URL_FILE="$SETUP_DIR/URLs/apple_id_password.url"
if [ -f "$APPLE_ID_URL_FILE" ]; then
  log "Opening Apple ID one-time password link"
  open "$APPLE_ID_URL_FILE"
  check_success "Opening Apple ID password link"

  # Ask user to confirm they've retrieved the password
  if [ "$FORCE" = false ]; then
    read -rp "Have you retrieved your Apple ID password? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log "Please retrieve your Apple ID password before continuing"
      open "$APPLE_ID_URL_FILE"
      read -p "Press any key to continue once you have your password... " -n 1 -r
      echo
    fi

    # Open System Settings to the Apple ID section
    log "Opening System Settings to the Apple ID section"
    log "IMPORTANT: You will need to complete several steps:"
    log "1. Enter your Apple ID and password"
    log "2. You may be prompted to enter your Mac's user password"
    log "3. Approve any verification codes that are sent to your other devices"
    log "4. Select which services to enable (you can customize these)"
    log "5. Return to Terminal after completing all Apple ID setup dialogs"

    open "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"
    check_success "Opening Apple ID settings"

    # Give user time to add their Apple ID
    read -rp "Please add your Apple ID in System Settings. Press any key when done... " -n 1 -r
    echo
  fi
else
  log "No Apple ID one-time password link found - you'll need to retrieve your password manually"
fi

# Create operator account if it doesn't exist
section "Setting Up Operator Account"
if dscl . -list /Users | grep -q "^$OPERATOR_USERNAME$"; then
  log "Operator account already exists"
else
  log "Creating operator account"

  # Read the password from the transferred file
  OPERATOR_PASSWORD_FILE="$SETUP_DIR/operator_password"
  if [ -f "$OPERATOR_PASSWORD_FILE" ]; then
    OPERATOR_PASSWORD=$(cat "$OPERATOR_PASSWORD_FILE")
    log "Using password from 1Password"
  else
    log "❌ Operator password file not found"
    exit 1
  fi

  # Create the operator account
  sudo sysadminctl -addUser "$OPERATOR_USERNAME" -fullName "$OPERATOR_FULLNAME" -password "$OPERATOR_PASSWORD" -hint "See 1Password TILSIT operator for password"
  check_success "Operator account creation"

  # Verify the password works
  if dscl /Local/Default -authonly "$OPERATOR_USERNAME" "$OPERATOR_PASSWORD"; then
    log "✅ Password verification successful"
  else
    log "❌ Password verification failed"
    exit 1
  fi

  # Store reference to 1Password (don't store actual password)
  echo "Operator account password is stored in 1Password: op://personal/TILSIT operator/password" > "/Users/$ADMIN_USERNAME/Documents/operator_password_reference.txt"
  chmod 600 "/Users/$ADMIN_USERNAME/Documents/operator_password_reference.txt"

  # Clean up the password file
  rm -f "$OPERATOR_PASSWORD_FILE"

  log "Operator account created successfully"

  # Set up operator SSH keys if available
  if [ -d "$SSH_KEY_SOURCE" ] && [ -f "$SSH_KEY_SOURCE/operator_authorized_keys" ]; then
    OPERATOR_SSH_DIR="/Users/$OPERATOR_USERNAME/.ssh"
    log "Setting up SSH keys for operator account"

    sudo mkdir -p "$OPERATOR_SSH_DIR"
    sudo cp "$SSH_KEY_SOURCE/operator_authorized_keys" "$OPERATOR_SSH_DIR/authorized_keys"
    sudo chmod 700 "$OPERATOR_SSH_DIR"
    sudo chmod 600 "$OPERATOR_SSH_DIR/authorized_keys"
    sudo chown -R "$OPERATOR_USERNAME" "$OPERATOR_SSH_DIR"

    check_success "Operator SSH key setup"
  fi
fi

# Configure power management settings
section "Configuring Power Management"
log "Setting power management for server use"

# Check current settings
CURRENT_SLEEP=$(pmset -g | grep -E "^[ ]*sleep" | awk '{print $2}')
CURRENT_DISPLAYSLEEP=$(pmset -g | grep -E "^[ ]*displaysleep" | awk '{print $2}')
CURRENT_DISKSLEEP=$(pmset -g | grep -E "^[ ]*disksleep" | awk '{print $2}')
CURRENT_WOMP=$(pmset -g | grep -E "^[ ]*womp" | awk '{print $2}')
CURRENT_AUTORESTART=$(pmset -g | grep -E "^[ ]*autorestart" | awk '{print $2}')

# Apply settings only if they differ from current
if [ "$CURRENT_SLEEP" != "0" ]; then
  sudo pmset -a sleep 0
  log "Disabled system sleep"
fi

if [ "$CURRENT_DISPLAYSLEEP" != "60" ]; then
  sudo pmset -a displaysleep 60  # Display sleeps after 1 hour
  log "Set display sleep to 60 minutes"
fi

if [ "$CURRENT_DISKSLEEP" != "0" ]; then
  sudo pmset -a disksleep 0
  log "Disabled disk sleep"
fi

if [ "$CURRENT_WOMP" != "1" ]; then
  sudo pmset -a womp 1  # Enable wake on network access
  log "Enabled Wake on Network Access"
fi

if [ "$CURRENT_AUTORESTART" != "1" ]; then
  sudo pmset -a autorestart 1  # Restart on power failure
  log "Enabled automatic restart after power failure"
fi

check_success "Power management configuration"

# Configure screen saver password requirement
section "Configuring screen saver password requirement"
defaults -currentHost write com.apple.screensaver askForPassword -int 1
defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 0
log "Enabled immediate password requirement after screen saver"

# Run software updates if not skipped
if [ "$SKIP_UPDATE" = false ]; then
  section "Running Software Updates"
  log "Checking for software updates (this may take a while)"

  # Check for updates
  UPDATE_CHECK=$(softwareupdate -l)
  if echo "$UPDATE_CHECK" | grep -q "No new software available"; then
    log "System is up to date"
  else
    log "Installing software updates in background mode"
    sudo softwareupdate -i -a --background
    check_success "Initiating background software update"
  fi
else
  log "Skipping software updates as requested"
fi

# Configure firewall
section "Configuring Firewall"

# Check if firewall is enabled using socketfilterfw
FIREWALL_STATE=$(sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate)

if [[ "$FIREWALL_STATE" =~ "disabled" ]]; then
  log "Enabling firewall"
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
  check_success "Firewall activation"
else
  log "Firewall is already enabled"
fi

# Add SSH to firewall allowed services
log "Ensuring SSH is allowed through firewall"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/sbin/sshd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/sbin/sshd

# Create scripts directory
section "Setting Up Scripts Directory"
SCRIPTS_DIR="/Users/$ADMIN_USERNAME/${HOSTNAME_LOWER}-scripts"
if [ ! -d "$SCRIPTS_DIR" ]; then
  log "Creating scripts directory"
  mkdir -p "$SCRIPTS_DIR"
  check_success "Scripts directory creation"
fi

# Copy package lists if available
if [ -f "$SETUP_DIR/lists/formulae.txt" ]; then
  log "Copying formulae list from setup directory"
  cp "$SETUP_DIR/lists/formulae.txt" "/Users/$ADMIN_USERNAME/"
  check_success "Formulae list copy"
fi

if [ -f "$SETUP_DIR/lists/casks.txt" ]; then
  log "Copying casks list from setup directory"
  cp "$SETUP_DIR/lists/casks.txt" "/Users/$ADMIN_USERNAME/"
  check_success "Casks list copy"
fi

# Configure security settings
section "Configuring Security Settings"

# Check and set firmware password if needed (skipped in this automated script for security)
log "Note: Firmware password should be set manually for security reasons"

# Disable automatic app downloads
defaults write com.apple.SoftwareUpdate AutomaticDownload -int 0
log "Disabled automatic app downloads"

#
# HOMEBREW & PACKAGE INSTALLATION
#

# Install Xcode Command Line Tools first
section "Installing Xcode Command Line Tools"

# Check if Xcode CLT is already installed
if xcode-select -p &>/dev/null; then
  log "Xcode Command Line Tools already installed at: $(xcode-select -p)"
else
  log "Installing Xcode Command Line Tools..."

  # Trigger the installation
  xcode-select --install
  sleep 1

  # Use AppleScript to automate the installation dialog
  log "Automating installation dialog..."
  osascript <<-EOD
    tell application "System Events"
      tell process "Install Command Line Developer Tools"
        keystroke return
        click button "Agree" of window "License Agreement"
      end tell
    end tell
EOD

  # Wait for installation to complete
  log "Waiting for Xcode Command Line Tools installation to complete..."
  while ! xcode-select -p &>/dev/null; do
    sleep 10
    log "Still waiting for Xcode CLT installation..."
  done

  log "✅ Xcode Command Line Tools installation completed"
fi

# Install Homebrew
if [ "$SKIP_HOMEBREW" = false ]; then
  section "Installing Homebrew"

  # Check if Homebrew is already installed
  if command -v brew &>/dev/null; then
    BREW_VERSION=$(brew --version | head -n 1 | awk '{print $2}')
    log "Homebrew is already installed (version $BREW_VERSION)"

    # Update Homebrew if already installed
    log "Updating Homebrew"
    brew update
    check_success "Homebrew update"
  else
    log "Installing Homebrew using official installation script"

    # Use the official Homebrew installation script
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    check_success "Homebrew installation"

    # Add Homebrew to path for current session
    if [[ "$(uname -m)" == "arm64" ]]; then
      HOMEBREW_PREFIX="/opt/homebrew"
    else
      HOMEBREW_PREFIX="/usr/local"
    fi

    # Add to shell configuration files
    for SHELL_PROFILE in ~/.zprofile ~/.bash_profile ~/.profile; do
      if [ -f "$SHELL_PROFILE" ]; then
        # Only add if not already present
        if ! grep -q "HOMEBREW_PREFIX" "$SHELL_PROFILE"; then
          log "Adding Homebrew to $SHELL_PROFILE"
          echo -e '\n# Homebrew' >> "$SHELL_PROFILE"
          echo "eval \"\$(${HOMEBREW_PREFIX}/bin/brew shellenv)\"" >> "$SHELL_PROFILE"
        fi
      fi
    done

    # Apply to current session
    eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"

    log "Homebrew installation completed"

    # Verify installation
    brew --version
    check_success "Homebrew verification"
  fi
fi

# Install packages
if [ "$SKIP_PACKAGES" = false ]; then
  section "Installing Packages"

  # Function to install formulae if not already installed
  install_formula() {
    if ! brew list "$1" &>/dev/null; then
      log "Installing formula: $1"
      brew install "$1"
      check_success "Formula installation: $1"
    else
      log "Formula already installed: $1"
    fi
  }

  # Function to install casks if not already installed
  install_cask() {
    if ! brew list --cask "$1" &>/dev/null 2>&1; then
      log "Installing cask: $1"
      brew install --cask "$1"
      check_success "Cask installation: $1"
    else
      log "Cask already installed: $1"
    fi
  }

  # Install formulae from list
  if [ -f "$FORMULAE_FILE" ]; then
    log "Installing formulae from $FORMULAE_FILE"
    while read -r formula; do
      [[ -z "$formula" || "$formula" == \#* ]] && continue
      install_formula "$formula"
    done < "$FORMULAE_FILE"
  else
    log "Formulae list not found, skipping formula installations"
  fi

  # Install casks from list
  if [ -f "$CASKS_FILE" ]; then
    log "Installing casks from $CASKS_FILE"
    while read -r cask; do
      [[ -z "$cask" || "$cask" == \#* ]] && continue
      install_cask "$cask"
    done < "$CASKS_FILE"
  else
    log "Casks list not found, skipping cask installations"
  fi

  # Cleanup after installation
  log "Cleaning up Homebrew files"
  brew cleanup
  check_success "Homebrew cleanup"
fi

#
# APPLICATION SETUP PREPARATION
#

# Create application setup directory
section "Preparing Application Setup"
APP_SETUP_DIR="/Users/$ADMIN_USERNAME/app-setup"

if [ ! -d "$APP_SETUP_DIR" ]; then
  log "Creating application setup directory"
  mkdir -p "$APP_SETUP_DIR"
  check_success "App setup directory creation"
fi

# Copy application setup scripts if available
if [ -d "$SETUP_DIR/scripts/app-setup" ]; then
  log "Copying application setup scripts from $SETUP_DIR/scripts/app-setup"
  cp "$SETUP_DIR/scripts/app-setup/"*.sh "$APP_SETUP_DIR/" 2>/dev/null
  chmod +x "$APP_SETUP_DIR/"*.sh 2>/dev/null
  check_success "Application scripts copy"
else
  log "No application setup scripts found in $SETUP_DIR/scripts/app-setup"
fi

# Configure automatic login for operator account
section "Configuring Automatic Login"
log "Setting up automatic login for $OPERATOR_USERNAME"

# Check if operator account exists
if ! dscl . -list /Users | grep -q "^$OPERATOR_USERNAME$"; then
  log "Operator account doesn't exist, cannot set up automatic login"
else
  # Read the password from 1Password reference
  if [ -f "/Users/$ADMIN_USERNAME/Documents/operator_password_reference.txt" ]; then
    log "Creating encoded password file for auto-login"

    # Get the password from the reference (we know it's in 1Password)
    # For auto-login, we need to recreate the password temporarily
    # This is a security tradeoff for convenience
    log "Note: Auto-login requires storing encoded password locally"
    log "Consider disabling auto-login for better security"

    # Skip auto-login setup for now - it requires storing the password
    log "Skipping auto-login setup for security reasons"
    log "You can enable it manually in System Settings > Users & Groups if desired"
  else
    log "Could not find operator password reference - skipping automatic login setup"
  fi
fi

# Setup completed successfully
section "Setup Complete"
log "Server setup has been completed successfully"
log "You can now set up individual applications with scripts in: $APP_SETUP_DIR"
log ""
log "Next steps:"
log "1. Set up applications: cd $APP_SETUP_DIR && ./plex-setup.sh"
log "2. Configure monitoring: ~/tilsit-scripts/monitoring-setup.sh"
log "3. Test SSH access from your dev machine: ssh operator@tilsit.local"

exit 0
