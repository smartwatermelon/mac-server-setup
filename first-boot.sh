#!/bin/bash
#
# first-boot.sh - Initial configuration script for Mac Mini M2 'TILSIT' server
#
# This script performs the initial setup tasks for the Mac Mini server after
# the macOS setup wizard has been completed. It configures:
# - Remote management (SSH)
# - User accounts
# - System settings
# - Power management
# - Security configurations
#
# Usage: ./first-boot.sh [--force] [--skip-update]
#   --force: Skip all confirmation prompts
#   --skip-update: Skip software updates (which can be time-consuming)
#
# Author: Claude
# Version: 1.1
# Created: 2025-05-13

# Exit on any error
set -e

# Configuration variables - adjust as needed
HOSTNAME="TILSIT"
OPERATOR_USERNAME="operator"
OPERATOR_FULLNAME="TILSIT Operator"
ADMIN_USERNAME=$(whoami)
LOG_FILE="/var/log/tilsit-setup.log"
SETUP_DIR="$HOME/tilsit-setup" # Directory where AirDropped files are located
SSH_KEY_SOURCE="$SETUP_DIR/ssh_keys"
PAM_D_SOURCE="$SETUP_DIR/pam.d"

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
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $1"
  echo "[$timestamp] $1" | sudo tee -a "$LOG_FILE" >/dev/null
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
  sudo touch "$LOG_FILE"
  sudo chmod 644 "$LOG_FILE"
fi

# Print header
section "Starting Mac Mini M2 'TILSIT' Server Setup"
log "Running as user: $ADMIN_USERNAME"
log "Date: $(date)"
log "macOS Version: $(sw_vers -productVersion)"

# Confirm operation if not forced
if [ "$FORCE" = false ]; then
  read -p "This script will configure your Mac Mini server. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
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
if sudo systemsetup -getremotelogin | grep -q "On"; then
  log "SSH is already enabled"
else
  log "Enabling SSH"
  sudo systemsetup -setremotelogin on
  check_success "SSH activation"
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

# TouchID sudo setup
if [ -d "$PAM_D_SOURCE" ]; then
  log "Found TouchID sudo setup in $PAM_D_SOURCE"
  if [ -f "$PAM_D_SOURCE/sudo_local" ]; then
    sudo cp "$PAM_D_SOURCE/sudo_local" "/etc/pam.d"
    check_success "TouchID sudo setup"
  else
    log "No sudo_local file found in $PAM_D_SOURCE"
  fi
else
  log "No TouchID sudo setup directory found at $PAM_D_SOURCE"
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

# Configure automatic login
section "Configuring Automatic Login"
if sudo defaults read /Library/Preferences/com.apple.loginwindow | grep -q "autoLoginUser"; then
  CURRENT_AUTOLOGIN=$(sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser)
  if [ "$CURRENT_AUTOLOGIN" = "$OPERATOR_USERNAME" ]; then
    log "Automatic login already configured for $OPERATOR_USERNAME"
  else
    log "Changing automatic login from $CURRENT_AUTOLOGIN to $OPERATOR_USERNAME"
    sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$OPERATOR_USERNAME"
    check_success "Automatic login configuration change"
  fi
else
  log "Setting up automatic login for $OPERATOR_USERNAME"
  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$OPERATOR_USERNAME"
  check_success "Automatic login configuration"
fi

# Run software updates if not skipped
if [ "$SKIP_UPDATE" = false ]; then
  section "Running Software Updates"
  log "Checking for software updates (this may take a while)"
  
  # Check for updates
  UPDATE_CHECK=$(softwareupdate -l)
  if echo "$UPDATE_CHECK" | grep -q "No new software available"; then
    log "System is up to date"
  else
    log "Installing software updates (this may take a long time)"
    sudo softwareupdate -i -a
    check_success "Software update installation"
  fi
else
  log "Skipping software updates as requested"
fi

# Configure firewall
section "Configuring Firewall"
FIREWALL_STATUS=$(sudo defaults read /Library/Preferences/com.apple.alf globalstate)

if [ "$FIREWALL_STATUS" = "0" ]; then
  log "Enabling firewall"
  sudo defaults write /Library/Preferences/com.apple.alf globalstate -int 1
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
SCRIPTS_DIR="/Users/$ADMIN_USERNAME/tilsit-scripts"
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
LAUNCH_AGENT_FILE="$LAUNCH_AGENT_DIR/com.tilsit.secondboot.plist"

if [ ! -d "$LAUNCH_AGENT_DIR" ]; then
  mkdir -p "$LAUNCH_AGENT_DIR"
fi

if [ -f "$LAUNCH_AGENT_FILE" ]; then
  log "Second-boot LaunchAgent already exists"
else
  log "Creating LaunchAgent for second-boot script"
  cat > "$LAUNCH_AGENT_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tilsit.secondboot</string>
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
    <string>/var/log/tilsit-secondboot.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/tilsit-secondboot.log</string>
</dict>
</plist>
EOF
  chmod 644 "$LAUNCH_AGENT_FILE"
  check_success "Second-boot LaunchAgent creation"
  
  # Load the LaunchAgent
  launchctl load "$LAUNCH_AGENT_FILE"
  check_success "Second-boot LaunchAgent loading"
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
