#!/bin/bash
#
# first-boot.command - Initial configuration script for Mac Mini M2 '$HOSTNAME' server
#
# This script performs the initial setup tasks for the Mac Mini server after
# the macOS setup wizard has been completed. It configures:
# - Remote management (SSH)
# - User accounts
# - System settings
# - Power management
# - Security configurations
#
# Usage: ./first-boot.command [--force] [--skip-update]
#   --force: Skip all confirmation prompts
#   --skip-update: Skip software updates (which can be time-consuming)
#
# Author: Claude
# Version: 1.3
# Created: 2025-05-16

# Exit on any error
set -e

# Configuration variables - adjust as needed
HOSTNAME="TILSIT"; HOSTNAME_LOWER="$( tr '[:upper:]' '[:lower:]' <<< $HOSTNAME)"
OPERATOR_USERNAME="operator"
OPERATOR_FULLNAME="$HOSTNAME Operator"
ADMIN_USERNAME=$(whoami)
export LOG_DIR; LOG_DIR="$HOME/.local/state" # XDG_STATE_HOME
LOG_FILE="$LOG_DIR/$HOSTNAME_LOWER-setup.log"
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # Directory where AirDropped files are located
SSH_KEY_SOURCE="$SETUP_DIR/ssh_keys"
PAM_D_SOURCE="$SETUP_DIR/pam.d"
WIFI_CONFIG_FILE="$SETUP_DIR/wifi/network.conf"
RERUN_AFTER_FDA=false

# Look for evidence we're being re-run after FDA grant
if [ -f "/tmp/${HOSTNAME_LOWER}_fda_requested" ]; then
    RERUN_AFTER_FDA=true
    rm -f "/tmp/${HOSTNAME_LOWER}_fda_requested"
    log "Detected re-run after Full Disk Access grant"
fi

# Parse command line arguments
FORCE=false
SKIP_UPDATE=false

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

# Confirm operation if not forced
if [ "$FORCE" = false ] && [ "$RERUN_AFTER_FDA" = false ]; then
  read -p "This script will configure your Mac Mini server. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

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
    networksetup -addpreferredwirelessnetworkatindex "$WIFI_IFACE" "$WIFI_SSID" 0 "WPA/WPA2" "$WIFI_PASSWORD"
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

# Set hostname
section "Setting Hostname"
if [ "$(hostname)" = "$HOSTNAME" ]; then
  log "Hostname is already set to $HOSTNAME"
else
  log "Setting hostname to $HOSTNAME"
  sudo scutil --set ComputerName "$HOSTNAME"
  sudo scutil --set LocalHostName "$HOSTNAME"
  sudo scutil --set HostName "$HOSTNAME"
  check_success "Hostname configuration"
fi

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
  # Generate a random password for the operator account
  OPERATOR_PASSWORD=$(openssl rand -base64 12)

  # Create the operator account
  sudo sysadminctl -addUser "$OPERATOR_USERNAME" -fullName "$OPERATOR_FULLNAME" -password "$OPERATOR_PASSWORD" -hint "See admin for password reset"
  check_success "Operator account creation"

  # Store the password in a secure location for admin reference
  echo "Operator account password: $OPERATOR_PASSWORD" > "/Users/$ADMIN_USERNAME/Documents/operator_password.txt"
  chmod 600 "/Users/$ADMIN_USERNAME/Documents/operator_password.txt"

  log "Operator account created with password saved to ~/Documents/operator_password.txt"

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

# Disable screen saver password
section "Configuring Screen Saver"
defaults -currentHost write com.apple.screensaver askForPassword -int 0
log "Disabled screen saver password requirement"

# Configure automatic login - temporarily use admin account
section "Configuring Temporary Automatic Login"
log "Setting up temporary automatic login for $ADMIN_USERNAME during setup"
sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$ADMIN_USERNAME"
check_success "Temporary automatic login configuration"

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

# Create scripts directory and copy second-boot script
section "Setting Up Scripts Directory"
SCRIPTS_DIR="/Users/$ADMIN_USERNAME/$HOSTNAME_LOWER-scripts"
if [ ! -d "$SCRIPTS_DIR" ]; then
  log "Creating scripts directory"
  mkdir -p "$SCRIPTS_DIR"
  check_success "Scripts directory creation"
fi

# Copy second-boot script if available
if [ -f "$SETUP_DIR/scripts/second-boot.sh" ]; then
  log "Copying second-boot script from setup directory"
  cp "$SETUP_DIR/scripts/second-boot.sh" "$SCRIPTS_DIR/"
  chmod +x "$SCRIPTS_DIR/second-boot.sh"
  check_success "Second-boot script copy"
else
  log "Error: Required second-boot.sh script not found in $SETUP_DIR/scripts/"
  if [ "$FORCE" = false ]; then
    read -p "This is a critical error. Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log "Exiting due to missing second-boot script"
      exit 1
    fi
  fi
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

# Set up automatic second-boot execution via LaunchAgent
LAUNCH_AGENT_DIR="/Users/$ADMIN_USERNAME/Library/LaunchAgents"
LAUNCH_AGENT_FILE="$LAUNCH_AGENT_DIR/com.$HOSTNAME_LOWER.secondboot.plist"

if [ ! -d "$LAUNCH_AGENT_DIR" ]; then
    mkdir -p "$LAUNCH_AGENT_DIR"
    log "Created LaunchAgents directory"
fi

if [ -f "$LAUNCH_AGENT_FILE" ]; then
    log "Second-boot LaunchAgent already exists, removing old version"
    launchctl unload "$LAUNCH_AGENT_FILE" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT_FILE"
fi

log "Creating LaunchAgent for second-boot script"
cat > "$LAUNCH_AGENT_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.$HOSTNAME_LOWER.secondboot</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPTS_DIR/second-boot.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>86400</integer>
    <key>StandardOutPath</key>
    <string>$HOME/.local/state/$HOSTNAME_LOWER-secondboot.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.local/state/$HOSTNAME_LOWER-secondboot.log</string>
</dict>
</plist>
EOF
chmod 644 "$LAUNCH_AGENT_FILE"
check_success "Second-boot LaunchAgent creation"

# Ensure we unload any existing version before loading
log "Unloading any existing LaunchAgent"
launchctl unload "$LAUNCH_AGENT_FILE" 2>/dev/null || true
log "Loading the LaunchAgent"
log "Command used for loading LaunchAgent: launchctl load -w \"$LAUNCH_AGENT_FILE\""
launchctl load -w "$LAUNCH_AGENT_FILE" 2>/tmp/launchctl_error.log || true
check_success "Second-boot LaunchAgent loading"
if [ -s "/tmp/launchctl_error.log" ]; then
    log "⚠️ Warning: launchctl reported errors: $(cat /tmp/launchctl_error.log)"
fi

# Immediately verify the LaunchAgent is registered
LOADED_AGENTS=$(launchctl list | grep com.$HOSTNAME_LOWER.secondboot || echo "")
if [ -n "$LOADED_AGENTS" ]; then
    log "Verified LaunchAgent is properly registered"
else
    log "⚠️ Warning: LaunchAgent doesn't appear to be registered. Will attempt to fix..."
    # Try a different approach
    log "Trying alternative LaunchAgent registration method"
    launchctl bootstrap gui/$(id -u) "$LAUNCH_AGENT_FILE"
    check_success "Alternative LaunchAgent registration"
fi

# Configure security settings
section "Configuring Security Settings"

# Check and set firmware password if needed (skipped in this automated script for security)
log "Note: Firmware password should be set manually for security reasons"

# Disable automatic app downloads
defaults write com.apple.SoftwareUpdate AutomaticDownload -int 0
log "Disabled automatic app downloads"

# Setup completed successfully
section "Setup Complete"
log "First-boot setup has been completed successfully"
log "System will need to be rebooted to apply all changes"

if [ "$FORCE" = false ]; then
  read -p "Reboot now? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Rebooting system now"
    sudo shutdown -r now
  else
    log "Please reboot manually when convenient"
  fi
fi

exit 0
