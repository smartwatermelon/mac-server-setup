#!/bin/bash

# Networking Setup Script for Mac Mini M2
# Purpose: Configure network settings, remote access, and security

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
    return 1
}

# Function for info messages
info() {
    echo -e "$1"
}

# Create a log directory and file
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/networking_setup.log"
touch "$LOGFILE"

# Function to log messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" >> "$LOGFILE"
}

# Function to check if command was successful
check_success() {
    if [ $? -eq 0 ]; then
        success "$1"
        log "✓ $1"
        return 0
    else
        error "$2"
        log "✗ $2"
        return 1
    fi
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$(dirname "$SCRIPT_DIR")/config.yaml"

# Check for configuration file
if [ ! -f "$CONFIG_FILE" ]; then
    error "Configuration file not found: $CONFIG_FILE"
    log "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Function to get configuration values
get_config() {
    yq eval "$1" "$CONFIG_FILE"
}

header "Networking and Remote Access Setup"
info "This script will configure network settings and remote access for your Mac Mini M2 server."
log "Networking setup started"

# SSH Remote Access Configuration
header "SSH Configuration"
log "Configuring SSH"

# Check if SSH is enabled in config
SSH_ENABLED=$(get_config '.remote_access.ssh.enabled')
SSH_PORT=$(get_config '.remote_access.ssh.port')
SSH_PASSWORD_AUTH=$(get_config '.remote_access.ssh.password_auth')

# Default to standard settings if not specified
SSH_PORT=${SSH_PORT:-22}
SSH_PASSWORD_AUTH=${SSH_PASSWORD_AUTH:-false}

if [ "$SSH_ENABLED" = "true" ]; then
    info "Enabling SSH remote access..."
    log "Enabling SSH remote access on port $SSH_PORT"
    
    # Enable SSH
    sudo systemsetup -setremotelogin on
    check_success "SSH remote login enabled" "Failed to enable SSH remote login"
    
    # Configure SSH settings
    info "Configuring SSH settings..."
    log "Configuring SSH settings"
    
    # Create /etc/ssh/sshd_config.d if it doesn't exist
    if [ ! -d "/etc/ssh/sshd_config.d" ]; then
        sudo mkdir -p /etc/ssh/sshd_config.d
    fi
    
    # Create custom SSH config
    sudo tee /etc/ssh/sshd_config.d/server-config.conf > /dev/null << EOL
# Custom SSH configuration for Mac Mini M2 Server

# Use non-standard port if specified
Port $SSH_PORT

# Security settings
PermitRootLogin no
MaxAuthTries 6
MaxSessions 10
LoginGraceTime 30

# Authentication settings
PubkeyAuthentication yes
PasswordAuthentication $([ "$SSH_PASSWORD_AUTH" = "true" ] && echo "yes" || echo "no")
PermitEmptyPasswords no
ChallengeResponseAuthentication no

# Other settings
X11Forwarding no
PrintMotd yes
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3
UseDNS no
EOL
    check_success "SSH configuration created" "Failed to create SSH configuration"
    
    # Restart SSH service to apply changes
    info "Restarting SSH service to apply changes..."
    log "Restarting SSH service"
    sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist
    sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist
    check_success "SSH service restarted" "Failed to restart SSH service"
    
    # Generate SSH key pair for current user if it doesn't exist
    if [ ! -f "$HOME/.ssh/id_rsa" ]; then
        info "Generating SSH key pair for current user..."
        log "Generating SSH key pair for current user"
        ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
        check_success "SSH key pair generated" "Failed to generate SSH key pair"
    else
        success "SSH key pair already exists for current user"
        log "SSH key pair already exists for current user"
    fi
    
    # Generate SSH key pair for operator user if needed
    OPERATOR_USER=$(get_config '.system.users.operator.name')
    if id "$OPERATOR_USER" &>/dev/null; then
        if [ ! -f "/Users/$OPERATOR_USER/.ssh/id_rsa" ]; then
            info "Generating SSH key pair for $OPERATOR_USER..."
            log "Generating SSH key pair for $OPERATOR_USER"
            
            # Create .ssh directory with proper permissions
            sudo -u $OPERATOR_USER mkdir -p "/Users/$OPERATOR_USER/.ssh"
            sudo -u $OPERATOR_USER chmod 700 "/Users/$OPERATOR_USER/.ssh"
            
            # Generate the key pair
            sudo -u $OPERATOR_USER ssh-keygen -t rsa -b 4096 -f "/Users/$OPERATOR_USER/.ssh/id_rsa" -N ""
            check_success "SSH key pair generated for $OPERATOR_USER" "Failed to generate SSH key pair for $OPERATOR_USER"
        else
            success "SSH key pair already exists for $OPERATOR_USER"
            log "SSH key pair already exists for $OPERATOR_USER"
        fi
    fi
else
    info "SSH remote access is disabled in configuration. Skipping SSH setup."
    log "SSH remote access is disabled in configuration"
fi

# Apple Remote Desktop Configuration
header "Remote Management Configuration"
log "Configuring Remote Management (ARD)"

# Check if remote management is enabled in config
REMOTE_MGMT_ENABLED=$(get_config '.remote_access.remote_management.enabled')

if [ "$REMOTE_MGMT_ENABLED" = "true" ]; then
    info "Enabling Apple Remote Desktop (Remote Management)..."
    log "Enabling Apple Remote Desktop (Remote Management)"
    
    # Enable Remote Management
    sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
        -activate -configure -access -on \
        -clientopts -setvnclegacy -vnclegacy yes \
        -clientopts -setvncpw -vncpw $(openssl rand -base64 12) \
        -restart -agent -privs -all
    
    check_success "Remote Management enabled" "Failed to enable Remote Management"
    
    # Print the VNC password (or securely store it)
    info "Remote Management has been enabled with a random password."
    info "Use the UI to set up specific user permissions if needed."
    log "Remote Management enabled with random password"
else
    info "Remote Management is disabled in configuration. Skipping Remote Management setup."
    log "Remote Management is disabled in configuration"
fi

# Network settings optimization
header "Network Settings Optimization"
log "Optimizing network settings for server use"

# Configure DNS settings if specified in config
# This would normally be done in System Preferences Network pane
# For automation, we'd likely need to use networksetup command:
# Example: sudo networksetup -setdnsservers "Wi-Fi" 8.8.8.8 8.8.4.4

# Optimize TCP settings for server use
info "Optimizing TCP settings for server use..."
log "Optimizing TCP settings for server use"

# Increase the maximum number of network files
sudo sysctl -w kern.maxfiles=65536
sudo sysctl -w kern.maxfilesperproc=32768

# Increase TCP buffer sizes
sudo sysctl -w net.inet.tcp.sendspace=262144
sudo sysctl -w net.inet.tcp.recvspace=262144

# Disable IP source routing
sudo sysctl -w net.inet.ip.sourceroute=0
sudo sysctl -w net.inet.ip.accept_sourceroute=0

# Disable ICMP redirect acceptance
sudo sysctl -w net.inet.ip.redirect=0

# Increase ARP cache size
sudo sysctl -w net.link.ether.inet.max_age=1200

check_success "TCP optimizations applied" "Failed to apply TCP optimizations"

# Make these changes permanent by creating a configuration file
info "Making network optimizations permanent..."
log "Making network optimizations permanent"

sudo tee /etc/sysctl.conf > /dev/null << EOL
# Optimized network settings for server use
kern.maxfiles=65536
kern.maxfilesperproc=32768
net.inet.tcp.sendspace=262144
net.inet.tcp.recvspace=262144
net.inet.ip.sourceroute=0
net.inet.ip.accept_sourceroute=0
net.inet.ip.redirect=0
net.link.ether.inet.max_age=1200
EOL

check_success "Network optimization configuration saved" "Failed to save network optimization configuration"

# Setup mDNS (Bonjour) advertising
header "Network Service Discovery"
log "Configuring mDNS service discovery"

info "Configuring mDNS/Bonjour service advertising..."
log "Configuring mDNS/Bonjour service advertising"

# Get the hostname
HOSTNAME=$(get_config '.system.hostname')

# Use defaults to configure mDNS settings
defaults write /Library/Preferences/com.apple.mDNSResponder.plist NoMulticastAdvertisements -bool false
defaults write /Library/Preferences/com.apple.mDNSResponder.plist UnicastPacketUsage -int 2

# Advertise SSH service via Bonjour if enabled
if [ "$SSH_ENABLED" = "true" ]; then
    # Create the SSH service definition file
    sudo tee /etc/avahi/services/ssh.service > /dev/null << EOL
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h SSH</name>
  <service>
    <type>_ssh._tcp</type>
    <port>$SSH_PORT</port>
  </service>
</service-group>
EOL
    check_success "SSH service advertisement configured" "Failed to configure SSH service advertisement"
fi

# Setup network monitoring
header "Network Monitoring Setup"
log "Setting up network monitoring"

info "Setting up network monitoring scripts..."
log "Setting up network monitoring scripts"

# Create network monitoring script
MONITOR_SCRIPT="$HOME/scripts/network_monitor.sh"

cat > "$MONITOR_SCRIPT" << EOL
#!/bin/bash

# Network monitoring script
LOG_FILE="$HOME/logs/network_monitor.log"
echo "\$(date): Running network status check" >> "\$LOG_FILE"

# Check basic connectivity
ping -c 3 8.8.8.8 > /dev/null 2>&1
if [ \$? -eq 0 ]; then
    echo "\$(date): Internet connectivity: OK" >> "\$LOG_FILE"
else
    echo "\$(date): Internet connectivity: FAILED" >> "\$LOG_FILE"
    # Send alert (could be email, notification, etc.)
fi

# Check DNS resolution
host google.com > /dev/null 2>&1
if [ \$? -eq 0 ]; then
    echo "\$(date): DNS resolution: OK" >> "\$LOG_FILE"
else
    echo "\$(date): DNS resolution: FAILED" >> "\$LOG_FILE"
    # Send alert
fi

# Get network interface statistics
INTERFACE=\$(route -n get default | grep interface | awk '{print \$2}')
echo "\$(date): Network interface statistics for \$INTERFACE:" >> "\$LOG_FILE"
netstat -I \$INTERFACE -b >> "\$LOG_FILE"

# Log active network connections
echo "\$(date): Active network connections:" >> "\$LOG_FILE"
netstat -an | grep ESTABLISHED >> "\$LOG_FILE"

# Monitor for unusual connection attempts (simplified)
echo "\$(date): Recent connection attempts:" >> "\$LOG_FILE"
netstat -an | grep SYN_RECV | wc -l >> "\$LOG_FILE"

# Optional: Check for container network issues if running
if command -v docker &> /dev/null; then
    if docker ps &> /dev/null; then
        echo "\$(date): Docker network status:" >> "\$LOG_FILE"
        docker network ls >> "\$LOG_FILE"
    fi
fi

# Rotate log file if too large (> 1MB)
if [ -f "\$LOG_FILE" ] && [ \$(stat -f%z "\$LOG_FILE") -gt 1048576 ]; then
    mv "\$LOG_FILE" "\$LOG_FILE.\$(date +%Y%m%d)"
    touch "\$LOG_FILE"
    echo "\$(date): Log file rotated" >> "\$LOG_FILE"
fi
EOL

chmod +x "$MONITOR_SCRIPT"
check_success "Network monitoring script created" "Failed to create network monitoring script"

# Create LaunchAgent for network monitoring
MONITOR_INTERVAL=$(get_config '.maintenance.monitoring.network_interval')
MONITOR_INTERVAL=${MONITOR_INTERVAL:-3600}  # Default to hourly if not specified

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.user.network_monitor.plist" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.network_monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>$MONITOR_SCRIPT</string>
    </array>
    <key>StartInterval</key>
    <integer>$MONITOR_INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/logs/network_monitor_out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/logs/network_monitor_err.log</string>
</dict>
</plist>
EOL

# Load the network monitoring LaunchAgent
info "Loading network monitoring LaunchAgent..."
log "Loading network monitoring LaunchAgent"
launchctl load "$HOME/Library/LaunchAgents/com.user.network_monitor.plist"
check_success "Network monitoring service started" "Failed to start network monitoring service"

# Final message
header "Network Configuration Completed"
log "Network configuration completed"

info "Your Mac Mini server has been configured with the following network settings:"
[ "$SSH_ENABLED" = "true" ] && info "  - SSH remote access enabled on port $SSH_PORT"
[ "$REMOTE_MGMT_ENABLED" = "true" ] && info "  - Apple Remote Desktop (Remote Management) enabled"
info "  - Network settings optimized for server performance"
info "  - mDNS service discovery configured"
info "  - Network monitoring scheduled every $(($MONITOR_INTERVAL / 60)) minutes"

success "Network configuration completed successfully!"
log "Network configuration completed successfully!"

# Return success
exit 0
