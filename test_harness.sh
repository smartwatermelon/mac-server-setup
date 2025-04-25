#!/bin/bash

# Test Harness for Mac Mini M2 Setup Scripts
# Purpose: Execute setup scripts with proper error handling, validation, and rollback capabilities

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

# Check if a script was provided
if [ $# -lt 1 ]; then
    error "No script specified. Usage: $0 <script_path>"
    exit 1
fi

SCRIPT="$1"
SCRIPT_NAME=$(basename "$SCRIPT")
SCRIPT_DIR=$(dirname "$SCRIPT")

# Check if the script exists
if [ ! -f "$SCRIPT" ]; then
    error "Script does not exist: $SCRIPT"
    exit 1
fi

# Make sure the script is executable
if [ ! -x "$SCRIPT" ]; then
    chmod +x "$SCRIPT"
fi

# Create a log directory if it doesn't exist
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"

# Create a timestamp for this run
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/${SCRIPT_NAME%.*}_${TIMESTAMP}.log"
BACKUP_DIR="$HOME/backups/${SCRIPT_NAME%.*}_${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

# Function to run the pre-execution checks
pre_checks() {
    header "Pre-Execution Checks for $SCRIPT_NAME"
    
    # Log start of execution
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Starting execution of $SCRIPT_NAME" > "$LOG_FILE"
    
    # Create backup of critical files that might be modified
    info "Creating backups before execution..."
    
    # Backup hostname settings
    if [[ "$SCRIPT_NAME" == *"initial_setup"* ]]; then
        sudo scutil --get ComputerName > "$BACKUP_DIR/ComputerName.txt" 2>/dev/null
        sudo scutil --get HostName > "$BACKUP_DIR/HostName.txt" 2>/dev/null
        sudo scutil --get LocalHostName > "$BACKUP_DIR/LocalHostName.txt" 2>/dev/null
        echo "Hostname settings backed up to $BACKUP_DIR" >> "$LOG_FILE"
    fi
    
    # Backup SSH configuration
    if [[ "$SCRIPT_NAME" == *"network"* ]]; then
        if [ -f "/etc/ssh/sshd_config" ]; then
            cp "/etc/ssh/sshd_config" "$BACKUP_DIR/" 2>/dev/null
        fi
        if [ -d "/etc/ssh/sshd_config.d" ]; then
            mkdir -p "$BACKUP_DIR/sshd_config.d"
            cp /etc/ssh/sshd_config.d/* "$BACKUP_DIR/sshd_config.d/" 2>/dev/null
        fi
        echo "SSH configuration backed up to $BACKUP_DIR" >> "$LOG_FILE"
    fi
    
    # Backup firewall settings
    if [[ "$SCRIPT_NAME" == *"network"* ]] || [[ "$SCRIPT_NAME" == *"initial_setup"* ]]; then
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate > "$BACKUP_DIR/firewall_state.txt" 2>/dev/null
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode > "$BACKUP_DIR/firewall_stealth.txt" 2>/dev/null
        echo "Firewall settings backed up to $BACKUP_DIR" >> "$LOG_FILE"
    fi
    
    # Backup NAS mount configuration
    if [[ "$SCRIPT_NAME" == *"nas"* ]]; then
        cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null
        mount > "$BACKUP_DIR/mounts.txt" 2>/dev/null
        echo "NAS mount configuration backed up to $BACKUP_DIR" >> "$LOG_FILE"
    fi
    
    # Backup LaunchAgents
    mkdir -p "$BACKUP_DIR/LaunchAgents"
    cp "$HOME/Library/LaunchAgents/"* "$BACKUP_DIR/LaunchAgents/" 2>/dev/null
    echo "LaunchAgents backed up to $BACKUP_DIR/LaunchAgents" >> "$LOG_FILE"
    
    success "Backups created in $BACKUP_DIR"
    
    # Check for dependencies
    info "Checking for dependencies..."
    
    # Check for Homebrew
    if [[ "$SCRIPT_NAME" == *"initial_setup"* ]]; then
        if ! command -v brew &> /dev/null; then
            warning "Homebrew is not installed. It will be installed by the script."
            echo "Homebrew not found, will be installed by the script" >> "$LOG_FILE"
        else
            success "Homebrew is installed"
            echo "Homebrew is installed" >> "$LOG_FILE"
        fi
    fi
    
    # Check for YAML parser
    if ! command -v yq &> /dev/null; then
        warning "yq (YAML parser) is not installed. It will be installed by the script."
        echo "yq not found, will be installed by the script" >> "$LOG_FILE"
    else
        success "yq (YAML parser) is installed"
        echo "yq is installed" >> "$LOG_FILE"
    fi
    
    # Check for network connectivity
    if ping -c 1 google.com &> /dev/null; then
        success "Network connectivity is available"
        echo "Network connectivity is available" >> "$LOG_FILE"
    else
        warning "Network connectivity is not available. Some script functions may fail."
        echo "Network connectivity is not available" >> "$LOG_FILE"
    fi
    
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Pre-execution checks completed" >> "$LOG_FILE"
    success "Pre-execution checks completed"
    return 0
}

# Function to run post-execution validations
post_checks() {
    header "Post-Execution Validation for $SCRIPT_NAME"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Starting post-execution validation" >> "$LOG_FILE"
    
    # Validate based on script type
    if [[ "$SCRIPT_NAME" == *"initial_setup"* ]]; then
        # Check hostname
        info "Checking hostname configuration..."
        CURRENT_HOSTNAME=$(scutil --get ComputerName)
        EXPECTED_HOSTNAME=$(grep "hostname" "$SCRIPT_DIR/../config.yaml" | cut -d ":" -f2 | tr -d ' "')
        
        if [ "$CURRENT_HOSTNAME" = "$EXPECTED_HOSTNAME" ]; then
            success "Hostname set correctly: $CURRENT_HOSTNAME"
            echo "Hostname set correctly: $CURRENT_HOSTNAME" >> "$LOG_FILE"
        else
            warning "Hostname mismatch. Expected: $EXPECTED_HOSTNAME, Actual: $CURRENT_HOSTNAME"
            echo "Hostname mismatch. Expected: $EXPECTED_HOSTNAME, Actual: $CURRENT_HOSTNAME" >> "$LOG_FILE"
        fi
        
        # Check Homebrew installation
        info "Checking Homebrew installation..."
        if command -v brew &> /dev/null; then
            success "Homebrew is installed"
            echo "Homebrew is installed" >> "$LOG_FILE"
        else
            error "Homebrew is not installed"
            echo "Homebrew is not installed" >> "$LOG_FILE"
        fi
        
        # Check if container runtime is installed
        info "Checking container runtime installation..."
        if command -v docker &> /dev/null; then
            success "Docker CLI is installed"
            echo "Docker CLI is installed" >> "$LOG_FILE"
        else
            warning "Docker CLI is not installed"
            echo "Docker CLI is not installed" >> "$LOG_FILE"
        fi
        
        if command -v colima &> /dev/null; then
            success "Colima container runtime is installed"
            echo "Colima container runtime is installed" >> "$LOG_FILE"
        else
            warning "Colima container runtime is not installed"
            echo "Colima container runtime is not installed" >> "$LOG_FILE"
        fi
    fi
    
    if [[ "$SCRIPT_NAME" == *"network"* ]]; then
        # Check SSH configuration
        info "Checking SSH configuration..."
        if sudo systemsetup -getremotelogin | grep "On" > /dev/null; then
            success "SSH remote login is enabled"
            echo "SSH remote login is enabled" >> "$LOG_FILE"
        else
            warning "SSH remote login is not enabled"
            echo "SSH remote login is not enabled" >> "$LOG_FILE"
        fi
        
        # Check firewall status
        info "Checking firewall status..."
        if sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate | grep "enabled" > /dev/null; then
            success "Firewall is enabled"
            echo "Firewall is enabled" >> "$LOG_FILE"
        else
            warning "Firewall is not enabled"
            echo "Firewall is not enabled" >> "$LOG_FILE"
        fi
        
        # Check for SSH keys
        info "Checking for SSH keys..."
        if [ -f "$HOME/.ssh/id_rsa" ]; then
            success "SSH key exists for current user"
            echo "SSH key exists for current user" >> "$LOG_FILE"
        else
            warning "SSH key does not exist for current user"
            echo "SSH key does not exist for current user" >> "$LOG_FILE"
        fi
    fi
    
    if [[ "$SCRIPT_NAME" == *"nas"* ]]; then
        # Check for NAS mounts
        info "Checking NAS mounts..."
        if grep -q "nfs\|smb\|afp" /etc/fstab; then
            success "NAS mount entries found in /etc/fstab"
            echo "NAS mount entries found in /etc/fstab" >> "$LOG_FILE"
        else
            warning "No NAS mount entries found in /etc/fstab"
            echo "No NAS mount entries found in /etc/fstab" >> "$LOG_FILE"
        fi
        
        # Check if any NAS mounts are currently mounted
        if mount | grep -q "/Users/.*NAS"; then
            success "NAS shares are currently mounted"
            echo "NAS shares are currently mounted" >> "$LOG_FILE"
        else
            warning "No NAS shares are currently mounted"
            echo "No NAS shares are currently mounted" >> "$LOG_FILE"
        fi
        
        # Check for NAS monitoring scripts
        if [ -f "$HOME/scripts/nas_monitor.sh" ]; then
            success "NAS monitoring script exists"
            echo "NAS monitoring script exists" >> "$LOG_FILE"
        else
            warning "NAS monitoring script does not exist"
            echo "NAS monitoring script does not exist" >> "$LOG_FILE"
        fi
    fi
    
    # Check LaunchAgents
    info "Checking LaunchAgents..."
    if ls "$HOME/Library/LaunchAgents/com.user."* &> /dev/null; then
        success "LaunchAgents are configured"
        echo "LaunchAgents are configured" >> "$LOG_FILE"
    else
        warning "No LaunchAgents found"
        echo "No LaunchAgents found" >> "$LOG_FILE"
    fi
    
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Post-execution validation completed" >> "$LOG_FILE"
    success "Post-execution validation completed"
    return 0
}

# Function to perform rollback if needed
rollback() {
    header "Performing Rollback for $SCRIPT_NAME"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Starting rollback procedure" >> "$LOG_FILE"
    
    info "Script execution failed. Attempting to restore from backup..."
    
    # Rollback based on script type
    if [[ "$SCRIPT_NAME" == *"initial_setup"* ]]; then
        # Restore hostname
        if [ -f "$BACKUP_DIR/ComputerName.txt" ]; then
            ORIGINAL_COMPUTER_NAME=$(cat "$BACKUP_DIR/ComputerName.txt")
            sudo scutil --set ComputerName "$ORIGINAL_COMPUTER_NAME"
            echo "Restored ComputerName to $ORIGINAL_COMPUTER_NAME" >> "$LOG_FILE"
        fi
        
        if [ -f "$BACKUP_DIR/HostName.txt" ]; then
            ORIGINAL_HOST_NAME=$(cat "$BACKUP_DIR/HostName.txt")
            sudo scutil --set HostName "$ORIGINAL_HOST_NAME"
            echo "Restored HostName to $ORIGINAL_HOST_NAME" >> "$LOG_FILE"
        fi
        
        if [ -f "$BACKUP_DIR/LocalHostName.txt" ]; then
            ORIGINAL_LOCAL_HOST_NAME=$(cat "$BACKUP_DIR/LocalHostName.txt")
            sudo scutil --set LocalHostName "$ORIGINAL_LOCAL_HOST_NAME"
            echo "Restored LocalHostName to $ORIGINAL_LOCAL_HOST_NAME" >> "$LOG_FILE"
        fi
    fi
    
    if [[ "$SCRIPT_NAME" == *"network"* ]]; then
        # Restore SSH configuration
        if [ -f "$BACKUP_DIR/sshd_config" ]; then
            sudo cp "$BACKUP_DIR/sshd_config" /etc/ssh/sshd_config
            echo "Restored SSH configuration" >> "$LOG_FILE"
        fi
        
        if [ -d "$BACKUP_DIR/sshd_config.d" ] && [ "$(ls -A "$BACKUP_DIR/sshd_config.d")" ]; then
            sudo cp "$BACKUP_DIR/sshd_config.d/"* /etc/ssh/sshd_config.d/
            echo "Restored SSH config.d files" >> "$LOG_FILE"
        fi
        
        # Restore firewall settings
        if [ -f "$BACKUP_DIR/firewall_state.txt" ]; then
            if grep -q "enabled" "$BACKUP_DIR/firewall_state.txt"; then
                sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
            else
                sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
            fi
            echo "Restored firewall state" >> "$LOG_FILE"
        fi
        
        if [ -f "$BACKUP_DIR/firewall_stealth.txt" ]; then
            if grep -q "enabled" "$BACKUP_DIR/firewall_stealth.txt"; then
                sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
            else
                sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode off
            fi
            echo "Restored firewall stealth mode" >> "$LOG_FILE"
        fi
    fi
    
    if [[ "$SCRIPT_NAME" == *"nas"* ]]; then
        # Restore NAS mount configuration
        if [ -f "$BACKUP_DIR/fstab" ]; then
            sudo cp "$BACKUP_DIR/fstab" /etc/fstab
            echo "Restored fstab configuration" >> "$LOG_FILE"
        fi
    fi
    
    # Restore LaunchAgents
    if [ -d "$BACKUP_DIR/LaunchAgents" ] && [ "$(ls -A "$BACKUP_DIR/LaunchAgents")" ]; then
        # Unload any new agents first
        for agent in "$HOME/Library/LaunchAgents/com.user."*; do
            if [ -f "$agent" ]; then
                launchctl unload "$agent" 2>/dev/null
                echo "Unloaded LaunchAgent: $(basename "$agent")" >> "$LOG_FILE"
            fi
        done
        
        # Copy back original agents
        cp "$BACKUP_DIR/LaunchAgents/"* "$HOME/Library/LaunchAgents/" 2>/dev/null
        
        # Reload original agents
        for agent in "$BACKUP_DIR/LaunchAgents/"*; do
            if [ -f "$agent" ]; then
                launchctl load "$HOME/Library/LaunchAgents/$(basename "$agent")" 2>/dev/null
                echo "Reloaded LaunchAgent: $(basename "$agent")" >> "$LOG_FILE"
            fi
        done
        
        echo "Restored LaunchAgents" >> "$LOG_FILE"
    fi
    
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Rollback completed" >> "$LOG_FILE"
    warning "Rollback completed. System state has been restored to pre-execution state."
    return 0
}

# Main execution
header "Test Harness: Executing $SCRIPT_NAME"
info "Log file: $LOG_FILE"

# Run pre-execution checks
pre_checks

# Execute the script
header "Executing $SCRIPT_NAME"
echo "$(date +"%Y-%m-%d %H:%M:%S") - Executing script: $SCRIPT" >> "$LOG_FILE"

set -o pipefail
"$SCRIPT" 2>&1 | tee -a "$LOG_FILE.output"
SCRIPT_EXIT_CODE=$?

echo "$(date +"%Y-%m-%d %H:%M:%S") - Script execution completed with exit code: $SCRIPT_EXIT_CODE" >> "$LOG_FILE"

# Handle script result
if [ $SCRIPT_EXIT_CODE -eq 0 ]; then
    success "Script executed successfully with exit code: $SCRIPT_EXIT_CODE"
    
    # Run post-execution validations
    post_checks
    POST_CHECK_EXIT_CODE=$?
    
    if [ $POST_CHECK_EXIT_CODE -eq 0 ]; then
        header "Execution Summary"
        success "Test harness execution completed successfully"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Test harness execution completed successfully" >> "$LOG_FILE"
        exit 0
    else
        header "Execution Summary"
        warning "Script executed, but post-execution validation failed"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Post-execution validation failed" >> "$LOG_FILE"
        
        read -p "Do you want to roll back the changes? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rollback
            exit 1
        else
            warning "Continuing without rollback"
            echo "$(date +"%Y-%m-%d %H:%M:%S") - Continuing without rollback" >> "$LOG_FILE"
            exit 1
        fi
    fi
else
    error "Script execution failed with exit code: $SCRIPT_EXIT_CODE"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - Script execution failed with exit code: $SCRIPT_EXIT_CODE" >> "$LOG_FILE"
    
    read -p "Do you want to roll back the changes? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rollback
        exit 1
    else
        warning "Continuing without rollback"
        echo "$(date +"%Y-%m-%d %H:%M:%S") - Continuing without rollback" >> "$LOG_FILE"
        exit 1
    fi
fi