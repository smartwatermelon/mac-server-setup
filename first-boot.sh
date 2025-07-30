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
# Version: 2.2
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

# log function - only writes to log file
log() {
  mkdir -p "$LOG_DIR"
  local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $1" >> "$LOG_FILE"
}

# New wrapper function - shows in main window AND logs
show_log() {
  echo "$1"
  log "$1"
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Function to check if a command was successful
check_success() {
  if [ $? -eq 0 ]; then
    show_log "✅ $1"
  else
    show_log "❌ $1 failed"
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

# Create log file if it doesn't exist, rotate if it exists
	if [ -f "$LOG_FILE" ]; then
		# Rotate existing log file with timestamp
		ROTATED_LOG="${LOG_FILE%.log}-$(date +%Y%m%d-%H%M%S).log"
		mv "$LOG_FILE" "$ROTATED_LOG"
		log "Rotated previous log to: $ROTATED_LOG"
	fi

	mkdir -p "$LOG_DIR"
	touch "$LOG_FILE"
	chmod 644 "$LOG_FILE"

# Tail log in separate window
osascript -e 'tell application "Terminal" to do script "printf \"\\e]0;TILSIT Setup Log\\a\"; tail -F '"$LOG_FILE"'"' || echo "oops, no tail"

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
      show_log "TouchID sudo needs to be configured. We will ask for your user password."
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
    # Check if we're already connected to the target network
    CURRENT_SSID=$(system_profiler SPAirPortDataType | awk '/Current Network/ {getline;$1=$1;print $0 | "tr -d \":\"";exit}')

    if [ "$CURRENT_SSID" = "$WIFI_SSID" ]; then
      log "Already connected to WiFi network: $WIFI_SSID"
    else
      log "Configuring WiFi network: $WIFI_SSID"

      # Check if SSID is already in preferred networks list
      WIFI_IFACE="$(system_profiler SPAirPortDataType -xml | /usr/libexec/PlistBuddy -c "Print :0:_items:0:spairport_airport_interfaces:0:_name" /dev/stdin <<< "$(cat)")"

      if networksetup -listpreferredwirelessnetworks "$WIFI_IFACE" | grep -q "$WIFI_SSID"; then
        log "WiFi network $WIFI_SSID is already in preferred networks list"
      else
        # Add WiFi network to preferred networks
        networksetup -addpreferredwirelessnetworkatindex "$WIFI_IFACE" "$WIFI_SSID" "@" "WPA/WPA2"
        check_success "Add preferred WiFi network"
        security add-generic-password -D "AirPort network password" -a "$WIFI_SSID" -s "AirPort" -w "$WIFI_PASSWORD" || true
        check_success "Store password in keychain"
      fi

      # Try to join the network
      log "Attempting to join WiFi network $WIFI_SSID..."
      networksetup -setairportnetwork "$WIFI_IFACE" "$WIFI_SSID" || true

      # Give it a few seconds and check if we connected
      sleep 5
      CURRENT_NETWORK=$(networksetup -getairportnetwork "$WIFI_IFACE" 2>/dev/null | cut -d' ' -f4- || echo "")
      if [ "$CURRENT_NETWORK" = "$WIFI_SSID" ]; then
        show_log "✅ Successfully connected to WiFi network: $WIFI_SSID"
      else
        show_log "WiFi network will be automatically joined after reboot"
      fi
    fi

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
      show_log "Please retrieve your Apple ID password before continuing"
      open "$APPLE_ID_URL_FILE"
      read -p "Press any key to continue once you have your password... " -n 1 -r
      echo
    fi

    # Open System Settings to the Apple ID section
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
    read -rp "Please add your Apple ID in System Settings. Press any key when done... " -n 1 -r
    echo

		# Configure iCloud and notification settings for admin user
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
		check_success "Notification settings configuration"

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
   show_log "✅ Password verification successful"
 else
   log "❌ Password verification failed"
   exit 1
 fi

 # Store reference to 1Password (don't store actual password)
 echo "Operator account password is stored in 1Password: op://personal/TILSIT operator/password" > "/Users/$ADMIN_USERNAME/Documents/operator_password_reference.txt"
 chmod 600 "/Users/$ADMIN_USERNAME/Documents/operator_password_reference.txt"

 show_log "Operator account created successfully"

	# Skip setup screens for operator account (more aggressive approach)
	 log "Configuring operator account to skip setup screens"
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.SetupAssistant DidSeeCloudSetup -bool true
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.SetupAssistant SkipCloudSetup -bool true
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.SetupAssistant DidSeePrivacy -bool true
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.SetupAssistant GestureMovieSeen none
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.SetupAssistant LastSeenCloudProductVersion "$(sw_vers -productVersion)"
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.screensaver showClock -bool false

	 # Screen Time and Apple Intelligence
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.ScreenTimeAgent DidCompleteSetup -bool true
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.intelligenceplatform.ui SetupHasBeenDisplayed -bool true

	 # Accessibility and Data & Privacy
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.universalaccess didSeeAccessibilitySetup -bool true
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.SetupAssistant DidSeeDataAndPrivacy -bool true

	 # TouchID setup bypass (this might help with the password confusion)
	 sudo -u "$OPERATOR_USERNAME" defaults write com.apple.SetupAssistant DidSeeTouchID -bool true
	 check_success "Operator setup screen suppression"

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

   # Add operator to SSH access group
   log "Adding operator to SSH access group"
   sudo dseditgroup -o edit -a "$OPERATOR_USERNAME" -t user com.apple.access_ssh
   check_success "Operator SSH group membership"
 fi
fi

# Configure automatic login for operator account (whether new or existing)
log "Configuring automatic login for operator account"
OPERATOR_PASSWORD_FILE="$SETUP_DIR/operator_password"
if [ -f "$OPERATOR_PASSWORD_FILE" ]; then
 OPERATOR_PASSWORD=$(cat "$OPERATOR_PASSWORD_FILE")

 # Create the encoded password file that macOS uses for auto-login
 echo "$OPERATOR_PASSWORD" | openssl enc -base64 | sudo tee /etc/kcpassword > /dev/null
 sudo chmod 600 /etc/kcpassword
 check_success "Create auto-login password file"

 # Set the auto-login user
 sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$OPERATOR_USERNAME"
 check_success "Set auto-login user"

 show_log "✅ Automatic login configured for $OPERATOR_USERNAME"

else
 log "Operator password file not found at $OPERATOR_PASSWORD_FILE - skipping automatic login setup"
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
  show_log "Checking for software updates (this may take a while)"

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

# Disable automatic app downloads
defaults write com.apple.SoftwareUpdate AutomaticDownload -int 0
log "Disabled automatic app downloads"

#
# HOMEBREW & PACKAGE INSTALLATION
#

# Install Xcode Command Line Tools if needed
section "Installing Xcode Command Line Tools"

# Check if CLT is already installed
if softwareupdate --history | grep 'Command Line Tools for Xcode' >/dev/null; then
  log "Xcode Command Line Tools already installed"
else
  show_log "Installing Xcode Command Line Tools silently..."

  # Touch flag to indicate user has requested CLT installation
  sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

  # Find and install the latest CLT package
  CLT_PACKAGE=$(softwareupdate -l | grep Label | tail -n 1 | cut -d ':' -f 2 | xargs)
  log "Installing package: $CLT_PACKAGE"

  softwareupdate -v -i "$CLT_PACKAGE"
  check_success "Xcode Command Line Tools installation"

  # Clean up the flag
  sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

  show_log "✅ Xcode Command Line Tools installation completed"
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
    show_log "Installing Homebrew using official installation script"

    # Use the official Homebrew installation script
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    check_success "Homebrew installation"

    # Follow Homebrew's suggested post-installation steps
    log "Running Homebrew's suggested post-installation steps"

    # Add Homebrew to path for current session
    if [[ "$(uname -m)" == "arm64" ]]; then
      HOMEBREW_PREFIX="/opt/homebrew"
    else
      HOMEBREW_PREFIX="/usr/local"
    fi

    # Add to .zprofile (Homebrew's recommended approach)
    echo >> "/Users/$ADMIN_USERNAME/.zprofile"
    echo "eval \"\$($HOMEBREW_PREFIX/bin/brew shellenv)\"" >> "/Users/$ADMIN_USERNAME/.zprofile"
    log "Added Homebrew to .zprofile"

    # Apply to current session
    eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
    log "Applied Homebrew environment to current session"

    # Add to other shell configuration files for compatibility
    for SHELL_PROFILE in ~/.bash_profile ~/.profile; do
      if [ -f "$SHELL_PROFILE" ]; then
        # Only add if not already present
        if ! grep -q "HOMEBREW_PREFIX\|brew shellenv" "$SHELL_PROFILE"; then
          log "Adding Homebrew to $SHELL_PROFILE"
          echo -e '\n# Homebrew' >> "$SHELL_PROFILE"
          echo "eval \"\$(${HOMEBREW_PREFIX}/bin/brew shellenv)\"" >> "$SHELL_PROFILE"
        fi
      fi
    done

    show_log "Homebrew installation completed"

    # Verify installation with brew help
    if brew help >/dev/null 2>&1; then
      show_log "✅ Homebrew verification successful"
    else
      log "❌ Homebrew verification failed - brew help returned an error"
      exit 1
    fi
  fi
fi

# Install packages
if [ "$SKIP_PACKAGES" = false ]; then
  section "Installing Packages"

  # Function to install formulae if not already installed
	install_formula() {
		if ! brew list "$1" &>/dev/null; then
			log "Installing formula: $1"
			if brew install "$1"; then
				log "✅ Formula installation: $1"
			else
				log "❌ Formula installation failed: $1"
				# Continue instead of exiting
			fi
		else
			log "Formula already installed: $1"
		fi
	}

  # Function to install casks if not already installed
  install_cask() {
    if ! brew list --cask "$1" &>/dev/null; then
      log "Installing cask: $1"
      if brew install --cask "$1"; then
				log "✅ Cask installation: $1"
			else
				log "❌ Cask installation failed: $1"
				# Continue instead of exiting
			fi
    else
      log "Cask already installed: $1"
    fi
  }

# Install formulae from list
 if [ -f "$FORMULAE_FILE" ]; then
	show_log "Installing formulae from $FORMULAE_FILE"
	formulae=()
	while IFS= read -r line; do
		formulae+=("$line")
	done < <(grep -v '^#' "$FORMULAE_FILE" | grep -v '^$')
	for formula in "${formulae[@]}"; do
	 install_formula "$formula"
	done
 else
	log "Formulae list not found, skipping formula installations"
 fi

 # Install casks from list
 if [ -f "$CASKS_FILE" ]; then
	show_log "Installing casks from $CASKS_FILE"
	casks=()
	while IFS= read -r line; do
		casks+=("$line")
	done < <(grep -v '^#' "$CASKS_FILE" | grep -v '^$')
	for cask in "${casks[@]}"; do
	 install_cask "$cask"
	done
 else
	log "Casks list not found, skipping cask installations"
 fi

  # Cleanup after installation
  log "Cleaning up Homebrew files"
  brew cleanup
  check_success "Homebrew cleanup"

  # Run brew doctor and save output
  log "Running brew doctor diagnostic"
  BREW_DOCTOR_OUTPUT="$LOG_DIR/brew-doctor-$(date +%Y%m%d-%H%M%S).log"
  brew doctor > "$BREW_DOCTOR_OUTPUT" 2>&1 || true
  log "Brew doctor output saved to: $BREW_DOCTOR_OUTPUT"
  check_success "Brew doctor diagnostic"
fi

#
# RELOAD PROFILE FOR CURRENT SESSION
#
section "Reload Profile"
# shellcheck source=/dev/null
source ~/.zprofile
check_success "Reload profile"

#
# CLEAN UP DOCK
#
section "Cleaning up Administrator Dock"
log "Cleaning up Administrator Dock"
if command -v dockutil &>/dev/null; then
	dockutil --remove Messages --remove Mail --remove Maps --remove Photos --remove FaceTime --remove Calendar --remove Contacts --remove Reminders --remove Freeform --remove TV --remove Music --remove News --remove 'iPhone Mirroring' --remove /System/Applications/Utilities/Terminal.app --allhomes --no-restart
	check_success "Administrator Dock cleaned up"
	dockutil --add /Applications/iTerm.app --allhomes --no-restart 2>/dev/null || true
	check_success "Add iTerm to Administrator Dock"
	killall Dock
else
	log "Could not locate dockutil"
fi

# Setup operator dock cleanup LaunchAgent
section "Setting Up Operator Dock Cleanup"

if [ -f "$SETUP_DIR/launch-agents/com.tilsit.operator.dockutil.plist" ] && dscl . -list /Users | grep -q "^$OPERATOR_USERNAME$"; then
  log "Installing operator dock cleanup LaunchAgent"

  # Create LaunchAgents directory for operator
  sudo -u "$OPERATOR_USERNAME" mkdir -p "/Users/$OPERATOR_USERNAME/Library/LaunchAgents"

  # Copy the plist file
  sudo cp "$SETUP_DIR/launch-agents/com.tilsit.operator.dockutil.plist" "/Users/$OPERATOR_USERNAME/Library/LaunchAgents/"
  sudo chown "$OPERATOR_USERNAME" "/Users/$OPERATOR_USERNAME/Library/LaunchAgents/com.tilsit.operator.dockutil.plist"

  # Bootstrap the LaunchAgent
  OPERATOR_UID=$(id -u "$OPERATOR_USERNAME")
  sudo launchctl bootstrap "gui/$OPERATOR_UID" "/Users/$OPERATOR_USERNAME/Library/LaunchAgents/com.tilsit.operator.dockutil.plist"
  check_success "Operator dock cleanup LaunchAgent setup"

  show_log "✅ Operator dock will be cleaned up on first login"
else
  log "Operator dock cleanup LaunchAgent not found or operator account doesn't exist"
fi

#
# CHANGE DEFAULT SHELL TO HOMEBREW BASH
#
section "Changing Default Shell to Homebrew Bash"

# Get the Homebrew bash path
HOMEBREW_BASH="$(brew --prefix)/bin/bash"

if [ -f "$HOMEBREW_BASH" ]; then
  log "Found Homebrew bash at: $HOMEBREW_BASH"

  # Add to /etc/shells if not already present
  if ! grep -q "$HOMEBREW_BASH" /etc/shells; then
    log "Adding Homebrew bash to /etc/shells"
    echo "$HOMEBREW_BASH" | sudo tee -a /etc/shells
    check_success "Add Homebrew bash to /etc/shells"
  else
    log "Homebrew bash already in /etc/shells"
  fi

  # Change shell for admin user
  if [ "$(dscl . -read /Users/"$ADMIN_USERNAME" UserShell | awk '{print $2}')" != "$HOMEBREW_BASH" ]; then
    log "Changing shell for admin user to Homebrew bash"
    sudo chsh -s "$HOMEBREW_BASH" "$ADMIN_USERNAME"
    check_success "Admin user shell change"
  else
    log "Admin user already using Homebrew bash"
  fi

  # Change shell for operator user if it exists
  if dscl . -list /Users | grep -q "^$OPERATOR_USERNAME$"; then
    if [ "$(dscl . -read /Users/$OPERATOR_USERNAME UserShell | awk '{print $2}')" != "$HOMEBREW_BASH" ]; then
      log "Changing shell for operator user to Homebrew bash"
      sudo chsh -s "$HOMEBREW_BASH" "$OPERATOR_USERNAME"
      check_success "Operator user shell change"
    else
      log "Operator user already using Homebrew bash"
    fi
  fi
else
  log "Homebrew bash not found - skipping shell change"
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

# Configure Time Machine backup
section "Configuring Time Machine"

# Check if Time Machine configuration is available
TIMEMACHINE_CONFIG_FILE="$SETUP_DIR/timemachine.conf"
if [ -f "$TIMEMACHINE_CONFIG_FILE" ]; then
  # Source the Time Machine configuration
  # shellcheck source=/dev/null
  source "$TIMEMACHINE_CONFIG_FILE"

  log "Configuring Time Machine destination: $TM_URL"
  # Construct the full SMB URL with credentials
  TIMEMACHINE_URL="smb://${TM_USERNAME}:${TM_PASSWORD}@${TM_URL#*://}"

  if sudo tmutil setdestination -a "$TIMEMACHINE_URL"; then
    check_success "Time Machine destination configuration"

    log "Enabling Time Machine"
    if sudo tmutil enable; then
      show_log "✅ Time Machine backup configured and enabled"
      check_success "Time Machine enable"

      # Add Time Machine to menu bar for admin user
      log "Adding Time Machine to menu bar"
      defaults write com.apple.systemuiserver menuExtras -array-add "/System/Library/CoreServices/Menu Extras/TimeMachine.menu"
      killall SystemUIServer
      check_success "Time Machine menu bar addition"
    else
      log "❌ Failed to enable Time Machine"
    fi
  else
    log "❌ Failed to set Time Machine destination"
  fi
else
  log "Time Machine configuration file not found - skipping Time Machine setup"
fi

# Setup completed successfully
section "Setup Complete"
show_log "Server setup has been completed successfully"
show_log "You can now set up individual applications with scripts in: $APP_SETUP_DIR"
show_log ""
show_log "Next steps:"
show_log "1. Set up applications: cd $APP_SETUP_DIR && ./plex-setup.sh"
show_log "2. Configure monitoring: ~/tilsit-scripts/monitoring-setup.sh"
show_log "3. Test SSH access from your dev machine:"
show_log "   ssh $ADMIN_USERNAME@tilsit.local"
show_log "   ssh operator@tilsit.local"

exit 0
