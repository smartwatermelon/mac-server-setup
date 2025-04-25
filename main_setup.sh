#!/bin/bash

# Main Setup Script for Mac Mini M2
# This script orchestrates the entire setup process

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function for section headers
header() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Function for success messages
success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function for warning messages
warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# Function for error messages
error() {
    echo -e "${RED}✗ $1${NC}"
}

# Function for info messages
info() {
    echo -e "$1"
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for configuration file
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    error "Configuration file not found: $CONFIG_FILE"
    info "Please make sure the config.yaml file exists in the script directory."
    exit 1
fi

# Create logs directory
mkdir -p "$HOME/logs"
MAIN_LOG="$HOME/logs/setup.log"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Setup started" >> "$MAIN_LOG"

# Load configuration using yq (YAML parser)
if ! command -v yq &> /dev/null; then
    info "Installing yq YAML parser..."
    brew install yq || {
        error "Failed to install yq. Please install it manually with 'brew install yq'."
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Failed to install yq" >> "$MAIN_LOG"
        exit 1
    }
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Installed yq" >> "$MAIN_LOG"
fi

# Extract configuration variables
get_config() {
    yq eval "$1" "$CONFIG_FILE"
}

# Welcome message
header "Mac Mini M2 Server Setup"
info "This script will set up your Mac Mini M2 as a home server."
info "Configuration file: $CONFIG_FILE"
echo ""

# Display hostname from configuration
HOSTNAME=$(get_config '.system.hostname')
info "Server hostname will be set to: $HOSTNAME"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Server hostname: $HOSTNAME" >> "$MAIN_LOG"

# Ask for administrator password upfront
sudo -v
# Keep-alive: update existing sudo time stamp until script has finished
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Check for all required scripts
INITIAL_SETUP="$SCRIPT_DIR/scripts/initial_setup.sh"
NETWORK_SETUP="$SCRIPT_DIR/scripts/networking_setup.sh"
NAS_SETUP="$SCRIPT_DIR/scripts/nas_setup.sh"
TEST_HARNESS="$SCRIPT_DIR/test_harness.sh"

# Array of required scripts
REQUIRED_SCRIPTS=("$INITIAL_SETUP" "$NETWORK_SETUP" "$NAS_SETUP" "$TEST_HARNESS")

# Verify all scripts exist
MISSING_SCRIPTS=false
for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [ ! -f "$script" ]; then
        error "Required script not found: $script"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Required script not found: $script" >> "$MAIN_LOG"
        MISSING_SCRIPTS=true
    else
        chmod +x "$script"
    fi
done

if [ "$MISSING_SCRIPTS" = true ]; then
    error "One or more required scripts are missing. Please check your installation."
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Setup failed: missing scripts" >> "$MAIN_LOG"
    exit 1
fi

# Pre-setup checks
header "Pre-Setup Validation"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Starting pre-setup validation" >> "$MAIN_LOG"

# Check internet connection
info "Checking internet connection..."
ping -c 3 google.com > /dev/null 2>&1
if [ $? -eq 0 ]; then
    success "Internet connection is available"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Internet connection available" >> "$MAIN_LOG"
else
    error "No internet connection available. Please connect to the internet and try again."
    echo "$(date +"%Y-%m-%d %H:%M:%S") - No internet connection" >> "$MAIN_LOG"
    exit 1
fi

# Check disk space
info "Checking available disk space..."
AVAILABLE_SPACE=$(df -h / | awk 'NR==2 {print $4}')
info "Available space: $AVAILABLE_SPACE"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Available disk space: $AVAILABLE_SPACE" >> "$MAIN_LOG"

# Convert to bytes for comparison (assuming GB)
AVAILABLE_GB=$(df / | awk 'NR==2 {print $4}')
if [ $AVAILABLE_GB -lt 10485760 ]; then  # 10GB in KB
    warning "Less than 10GB of free space available. This may not be sufficient."
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Low disk space warning" >> "$MAIN_LOG"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Setup aborted by user."
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Setup aborted by user due to low disk space" >> "$MAIN_LOG"
        exit 0
    fi
else
    success "Sufficient disk space available"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Sufficient disk space available" >> "$MAIN_LOG"
fi

# Check if running as admin user
info "Checking user permissions..."
echo "$(date +"%Y-%m-%d %H:%M:%S") - Checking user permissions" >> "$MAIN_LOG"
if [ "$(id -u)" -eq 0 ]; then
    error "This script should not be run as root. Please run as a regular admin user."
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Script running as root (not allowed)" >> "$MAIN_LOG"
    exit 1
fi

# Check if user has admin privileges
if groups $(whoami) | grep -q admin; then
    success "User has admin privileges"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - User has admin privileges" >> "$MAIN_LOG"
else
    error "Current user does not have admin privileges. Please run as an admin user."
    echo "$(date +"%Y-%m-%d %H:%M:%S") - User does not have admin privileges" >> "$MAIN_LOG"
    exit 1
fi

# Create necessary directories
info "Creating necessary directories..."
mkdir -p "$HOME/logs"
mkdir -p "$HOME/backups"
mkdir -p "$HOME/scripts"
mkdir -p "$HOME/NAS"
success "Directory structure created"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Directory structure created" >> "$MAIN_LOG"

# Backup existing configuration
header "Backing Up Existing Configuration"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Backing up existing configuration" >> "$MAIN_LOG"

BACKUP_DIR="$HOME/backups/$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

info "Creating backup of system configuration..."
# Backup hostname
sudo scutil --get ComputerName > "$BACKUP_DIR/ComputerName.txt" 2>/dev/null
sudo scutil --get HostName > "$BACKUP_DIR/HostName.txt" 2>/dev/null
sudo scutil --get LocalHostName > "$BACKUP_DIR/LocalHostName.txt" 2>/dev/null

# Backup SSH configuration
if [ -f "/etc/ssh/sshd_config" ]; then
    cp "/etc/ssh/sshd_config" "$BACKUP_DIR/" 2>/dev/null
fi

# Backup firewall settings
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate > "$BACKUP_DIR/firewall_state.txt" 2>/dev/null
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode > "$BACKUP_DIR/firewall_stealth.txt" 2>/dev/null

# Backup network settings
networksetup -listallnetworkservices > "$BACKUP_DIR/network_services.txt" 2>/dev/null

# Backup mounted volumes
mount > "$BACKUP_DIR/mounts.txt" 2>/dev/null

success "Backup completed: $BACKUP_DIR"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Backup completed: $BACKUP_DIR" >> "$MAIN_LOG"

# Ask for confirmation before proceeding
header "Ready to Begin Setup"
info "All pre-setup checks have passed."
info "The setup will perform the following operations:"
echo "  1. Initial system configuration (hostname, power settings, etc.)"
echo "  2. Install Homebrew and required packages"
echo "  3. Set up networking and remote access"
echo "  4. Configure NAS connections for media storage"
echo ""
read -p "Do you want to proceed with the setup? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Setup aborted by user."
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Setup aborted by user at confirmation prompt" >> "$MAIN_LOG"
    exit 0
fi

# Function to run scripts with the test harness and handle errors
run_script() {
    local script=$1
    local description=$2
    local step=$3
    local total_steps=$4
    
    header "Step $step/$total_steps: $description"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Starting step $step/$total_steps: $description" >> "$MAIN_LOG"
    
    "$TEST_HARNESS" "$script"
    local result=$?
    
    if [ $result -ne 0 ]; then
        warning "$description encountered issues. Check logs for details."
        echo "$(date +"%Y-%m-%d %H:%M:%S") - $description encountered issues" >> "$MAIN_LOG"
        
        read -p "Continue with the next step? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Setup aborted by user after $description."
            echo "$(date +"%Y-%m-%d %H:%M:%S") - Setup aborted by user after $description" >> "$MAIN_LOG"
            exit 1
        fi
    else
        success "$description completed successfully"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - $description completed successfully" >> "$MAIN_LOG"
    fi
    
    return $result
}

# Process each script using the test harness
header "Starting Setup Process"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Starting setup process" >> "$MAIN_LOG"

# Step 1: Initial Setup
run_script "$INITIAL_SETUP" "Initial System Setup" 1 3
INITIAL_RESULT=$?

# Step 2: Network Setup
run_script "$NETWORK_SETUP" "Network Configuration" 2 3
NETWORK_RESULT=$?

# Step 3: NAS Setup
run_script "$NAS_SETUP" "NAS Configuration" 3 3
NAS_RESULT=$?

# Final verification
header "Final Verification"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Starting final verification" >> "$MAIN_LOG"

# Verify hostname
info "Verifying hostname..."
CURRENT_HOSTNAME=$(scutil --get ComputerName)
if [ "$CURRENT_HOSTNAME" = "$HOSTNAME" ]; then
    success "Hostname set correctly: $CURRENT_HOSTNAME"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Hostname verified: $CURRENT_HOSTNAME" >> "$MAIN_LOG"
else
    warning "Hostname mismatch. Expected: $HOSTNAME, Actual: $CURRENT_HOSTNAME"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Hostname mismatch" >> "$MAIN_LOG"
fi

# Verify Docker/container runtime
info "Verifying container runtime..."
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        success "Docker is installed and running"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Docker is installed and running" >> "$MAIN_LOG"
    else
        warning "Docker is installed but not running"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Docker is installed but not running" >> "$MAIN_LOG"
    fi
else
    warning "Docker is not installed"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Docker is not installed" >> "$MAIN_LOG"
fi

# Verify SSH
info "Verifying SSH remote access..."
if sudo systemsetup -getremotelogin | grep "On" > /dev/null; then
    success "SSH remote login is enabled"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - SSH remote login is enabled" >> "$MAIN_LOG"
else
    warning "SSH remote login is not enabled"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - SSH remote login is not enabled" >> "$MAIN_LOG"
fi

# Verify NAS mounts
info "Verifying NAS mounts..."
MOUNT_COUNT=$(get_config '.nas.mounts | length')
MOUNTED_COUNT=0
TOTAL_MOUNTS=0

for i in $(seq 0 $(($MOUNT_COUNT - 1))); do
    NAME=$(get_config ".nas.mounts[$i].name")
    MOUNT_POINT=$(get_config ".nas.mounts[$i].mount_point")
    
    # Skip if incomplete configuration
    if [ -z "$NAME" ] || [ -z "$MOUNT_POINT" ]; then
        continue
    fi
    
    # Substitute user home paths if needed
    MOUNT_POINT="${MOUNT_POINT/#\~/$HOME}"
    MOUNT_POINT="${MOUNT_POINT/#\$HOME/$HOME}"
    
    # Substitute operator user if needed
    OPERATOR_USER=$(get_config '.system.users.operator.name')
    if [ -n "$OPERATOR_USER" ]; then
        MOUNT_POINT="${MOUNT_POINT//\$OPERATOR_USER/$OPERATOR_USER}"
        OPERATOR_HOME="/Users/$OPERATOR_USER"
        MOUNT_POINT="${MOUNT_POINT/#\~/$OPERATOR_HOME}"
    fi
    
    TOTAL_MOUNTS=$((TOTAL_MOUNTS + 1))
    
    if mountpoint -q "$MOUNT_POINT"; then
        success "NAS mount $NAME is mounted at $MOUNT_POINT"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - NAS mount $NAME is mounted at $MOUNT_POINT" >> "$MAIN_LOG"
        MOUNTED_COUNT=$((MOUNTED_COUNT + 1))
    else
        warning "NAS mount $NAME is not mounted at $MOUNT_POINT"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - NAS mount $NAME is not mounted at $MOUNT_POINT" >> "$MAIN_LOG"
    fi
done

if [ $TOTAL_MOUNTS -gt 0 ]; then
    info "$MOUNTED_COUNT out of $TOTAL_MOUNTS NAS mounts are active"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $MOUNTED_COUNT out of $TOTAL_MOUNTS NAS mounts are active" >> "$MAIN_LOG"
fi

# Check for failed steps
FAILED_STEPS=0
[ $INITIAL_RESULT -ne 0 ] && FAILED_STEPS=$((FAILED_STEPS + 1))
[ $NETWORK_RESULT -ne 0 ] && FAILED_STEPS=$((FAILED_STEPS + 1))
[ $NAS_RESULT -ne 0 ] && FAILED_STEPS=$((FAILED_STEPS + 1))

# Final message with status
header "Setup Complete"
if [ $FAILED_STEPS -eq 0 ]; then
    info "Your Mac Mini M2 has been successfully configured as a home server!"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Setup completed successfully" >> "$MAIN_LOG"
else
    warning "Setup completed with $FAILED_STEPS failed steps. Check logs for details."
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Setup completed with $FAILED_STEPS failed steps" >> "$MAIN_LOG"
fi

echo ""
info "Here are some important next steps and information:"
echo ""
info "1. Access your server remotely via SSH:"
info "   ssh $(whoami)@$HOSTNAME.local"
echo ""
info "2. Log files are stored in:"
info "   $HOME/logs"
echo ""
info "3. For NAS configuration issues, check mount points and configuration in:"
info "   $CONFIG_FILE"
echo ""
info "4. To deploy containerized applications, use the Docker Compose example provided"
echo ""

if [ $FAILED_STEPS -eq 0 ]; then
    success "Mac Mini M2 Server setup completed successfully!"
else
    warning "Mac Mini M2 Server setup completed with some issues."
    info "Please review the logs and fix any remaining issues."
fi

echo "$(date +"%Y-%m-%d %H:%M:%S") - Setup process finished" >> "$MAIN_LOG"
exit $FAILED_STEPS
