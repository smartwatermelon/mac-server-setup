#!/bin/bash
#
# usb-setup.sh - Script to prepare USB drive with necessary files for Mac Mini M2 'TILSIT' server setup
#
# This script prepares a USB drive with all the necessary scripts and files
# for setting up the Mac Mini M2 server. It should be run on your development machine.
#
# Usage: ./usb-setup.sh [usb_mount_path]
#   usb_mount_path: Path where the USB drive is mounted (default: /Volumes/USB)
#
# Author: Claude
# Version: 1.0
# Created: 2025-05-13

# Exit on error
set -e

# Configuration
USB_PATH="${1:-/Volumes/USB}"
GITHUB_REPO="https://github.com/yourusername/tilsit-setup.git"  # Replace with your actual repository
SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"  # Adjust to your SSH key path

# Check if USB drive is mounted
if [ ! -d "$USB_PATH" ]; then
  echo "Error: USB drive not found at $USB_PATH"
  echo "Please connect a USB drive and run this script again, or specify the correct path:"
  echo "  ./usb-setup.sh /path/to/usb"
  exit 1
fi

echo "====== Preparing USB Drive for TILSIT Server Setup ======"
echo "USB drive path: $USB_PATH"
echo "Date: $(date)"

# Create directory structure
echo "Creating directory structure..."
mkdir -p "$USB_PATH/ssh_keys"
mkdir -p "$USB_PATH/scripts"
mkdir -p "$USB_PATH/scripts/app-setup"
mkdir -p "$USB_PATH/lists"

# Copy SSH keys
if [ -f "$SSH_KEY_PATH" ]; then
  echo "Copying SSH public key..."
  cp "$SSH_KEY_PATH" "$USB_PATH/ssh_keys/authorized_keys"
  
  # Create operator keys (same as admin for now)
  cp "$SSH_KEY_PATH" "$USB_PATH/ssh_keys/operator_authorized_keys"
else
  echo "Warning: SSH public key not found at $SSH_KEY_PATH"
  echo "Please generate SSH keys or specify the correct path"
fi

# Option 1: Clone from GitHub repository if available
if [[ -n "$GITHUB_REPO" && "$GITHUB_REPO" != "https://github.com/yourusername/tilsit-setup.git" ]]; then
  echo "Cloning setup scripts from GitHub repository..."
  
  # Create temporary directory
  TMP_DIR=$(mktemp -d)
  
  # Clone repository
  git clone "$GITHUB_REPO" "$TMP_DIR"
  
  # Copy scripts to USB
  cp "$TMP_DIR/first-boot.sh" "$USB_PATH/scripts/"
  cp "$TMP_DIR/second-boot.sh" "$USB_PATH/scripts/"
  cp "$TMP_DIR/app-setup/"*.sh "$USB_PATH/scripts/app-setup/"
  cp "$TMP_DIR/formulae.txt" "$USB_PATH/lists/"
  cp "$TMP_DIR/casks.txt" "$USB_PATH/lists/"
  
  # Clean up
  rm -rf "$TMP_DIR"
  
  echo "Scripts copied from GitHub repository"
else
  # Option 2: Create scripts directly if repository not specified
  echo "Creating setup scripts directly..."
  
  # Create first-boot.sh
  cat > "$USB_PATH/scripts/first-boot.sh" << 'EOF'
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
# Version: 1.0
# Created: 2025-05-13

# Exit on any error
set -e

# Configuration variables - adjust as needed
HOSTNAME="TILSIT"
OPERATOR_USERNAME="operator"
OPERATOR_FULLNAME="TILSIT Operator"
ADMIN_USERNAME=$(whoami)
LOG_FILE="/var/log/tilsit-setup.log"
SSH_KEY_SOURCE="/Volumes/USB/ssh_keys" # Adjust based on your USB drive name

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

# Create scripts directory
section "Setting Up Scripts Directory"
SCRIPTS_DIR="/Users/$ADMIN_USERNAME/tilsit-scripts"
if [ ! -d "$SCRIPTS_DIR" ]; then
  log "Creating scripts directory"
  mkdir -p "$SCRIPTS_DIR"
  check_success "Scripts directory creation"
fi

# Copy second-boot script if available
if [ -f "/Volumes/USB/scripts/second-boot.sh" ]; then
  log "Copying second-boot script from USB"
  cp "/Volumes/USB/scripts/second-boot.sh" "$SCRIPTS_DIR/"
  chmod +x "$SCRIPTS_DIR/second-boot.sh"
  check_success "Second-boot script copy"
else
  # Create second-boot script placeholder
  SECOND_BOOT_SCRIPT="$SCRIPTS_DIR/second-boot.sh"
  log "Creating second-boot script placeholder"
  cat > "$SECOND_BOOT_SCRIPT" << 'EOF'
#!/bin/bash
# Second-boot setup script - will be replaced by actual script
echo "Placeholder for second-boot setup script"
echo "Replace this file with the actual second-boot.sh script before running"
EOF
  chmod +x "$SECOND_BOOT_SCRIPT"
  check_success "Second-boot script placeholder creation"
fi

# Copy package lists if available
if [ -f "/Volumes/USB/lists/formulae.txt" ]; then
  log "Copying formulae list from USB"
  cp "/Volumes/USB/lists/formulae.txt" "/Users/$ADMIN_USERNAME/"
  check_success "Formulae list copy"
fi

if [ -f "/Volumes/USB/lists/casks.txt" ]; then
  log "Copying casks list from USB"
  cp "/Volumes/USB/lists/casks.txt" "/Users/$ADMIN_USERNAME/"
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
EOF
  chmod +x "$USB_PATH/scripts/first-boot.sh"
  
  # Create second-boot.sh (abbreviated version, just a reference)
  cat > "$USB_PATH/scripts/second-boot.sh" << 'EOF'
#!/bin/bash
#
# second-boot.sh - Secondary setup script for Mac Mini M2 'TILSIT' server
#
# This script handles Homebrew installation and package management.
# See the full version for complete implementation.
#
# Usage: ./second-boot.sh [--force] [--skip-homebrew] [--skip-packages]

echo "This is a placeholder for the second-boot.sh script"
echo "Please replace with the full implementation from the runbook"
echo "or copy from the GitHub repository"

exit 0
EOF
  chmod +x "$USB_PATH/scripts/second-boot.sh"
  
  # Create formulae.txt
  cat > "$USB_PATH/lists/formulae.txt" << 'EOF'
bash
bash-completion@2
bat
brew-cask-completion
coreutils
ffmpeg
findutils
gawk
gh
git
gnu-getopt
gnu-sed
gnu-tar
gnu-time
gnu-units
gnu-which
gnupg
grep
imagemagick
iproute2mac
launchctl-completion
less
liquidprompt
mas
nmap
node
open-completion
openssh
pipx
pv
python@3.13
qrencode
ripgrep-all
rsync
s-search
shellcheck
speedtest
telnet
terminal-notifier
vim
watch
yt-dlp
EOF

  # Create casks.txt
  cat > "$USB_PATH/lists/casks.txt" << 'EOF'
1password
1password-cli
appcleaner
backblaze
bbedit
blockblock
catch
claude
coconutbattery
coconutid
docker
dropbox
filebot
font-inconsolata
garmin-express
google-chrome
google-drive
hiddenbar
hot
knockknock
lulu
macdown
no-ip-duc
notunes
plex-media-server
serial
slack
stay
taskexplorer
transmission
virtualbox
vlc
zoom
EOF

  echo "Scripts and lists created directly on USB drive"
fi

# Create a README file
echo "Creating README file..."
cat > "$USB_PATH/README.md" << 'EOF'
# TILSIT Server Setup USB

This USB drive contains all the necessary files for setting up the Mac Mini M2 'TILSIT' server.

## Contents

- `ssh_keys/`: SSH public keys for secure remote access
- `scripts/`: Setup scripts for the server
- `lists/`: Homebrew formulae and casks lists

## Setup Instructions

1. Complete the macOS setup wizard on the Mac Mini
2. Insert this USB drive
3. Open Terminal and run:

```bash
cd /Volumes/USB/scripts
./first-boot.sh
```

4. Follow the on-screen instructions
5. After reboot, the second-boot script will run automatically

For detailed instructions, refer to the complete runbook.

## Notes

- The operator account password will be saved to `~/Documents/operator_password.txt`
- After setup, you can access the server via SSH using the admin or operator account

Created: $(date)
EOF

echo "Setting file permissions..."
chmod -R 755 "$USB_PATH/scripts"

echo "====== USB Drive Preparation Complete ======"
echo "The USB drive at $USB_PATH is now ready for use."
echo "Insert it into the Mac Mini after completing the macOS setup wizard"
echo "and run the first-boot.sh script."

exit 0
