#!/bin/bash

# NAS Setup Script for Mac Mini M2
# Purpose: Configure NAS mounts for media storage

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
LOGFILE="$LOG_DIR/nas_setup.log"
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

header "NAS Setup and Configuration"
info "This script will configure NAS mounts for your Mac Mini M2 server."
log "NAS setup started"

# Check if NAS is enabled in configuration
NAS_ENABLED=$(get_config '.nas.enabled')

if [ "$NAS_ENABLED" != "true" ]; then
    info "NAS integration is disabled in configuration. Skipping NAS setup."
    log "NAS integration is disabled in configuration"
    exit 0
fi

# Get NAS configuration values
NAS_MOUNT_TYPE=$(get_config '.nas.mount_type')
# NAS_MOUNTS_JSON=$(get_config '.nas.mounts')	# unused?

# Validate NAS configuration
if [ -z "$NAS_MOUNT_TYPE" ]; then
    warning "NAS mount type not specified. Defaulting to NFS."
    log "NAS mount type not specified. Defaulting to NFS."
    NAS_MOUNT_TYPE="nfs"
fi

# Setup based on mount type
header "Setting Up $NAS_MOUNT_TYPE Mounts"
log "Setting up $NAS_MOUNT_TYPE mounts"

# Get operator user for file ownership
OPERATOR_USER=$(get_config '.system.users.operator.name')

# Function to configure automounting for an NFS share
configure_nfs_mount() {
    local name=$1
    local server=$2
    local share=$3
    local mount_point=$4
    local options=$5
    
    info "Configuring NFS mount for $name..."
    log "Configuring NFS mount for $name at $mount_point"
    
    # Ensure mount point exists
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
        if [ -n "$OPERATOR_USER" ] && id "$OPERATOR_USER" &>/dev/null; then
            chown "$OPERATOR_USER" "$mount_point"
        fi
        success "Created mount point: $mount_point"
        log "Created mount point: $mount_point"
    fi
    
    # Test the connection
    info "Testing NFS connection to $server:$share..."
    log "Testing NFS connection to $server:$share"
    
    # Check if the server and share are accessible
    if ! showmount -e "$server" | grep -q "$share"; then
        warning "Could not verify NFS share $server:$share. It might not be exported or the server might be unreachable."
        log "Could not verify NFS share $server:$share"
        # Continue anyway as the server might be reachable later
    fi
    
    # Create the mount entry in /etc/fstab
    if ! grep -q "$server:$share" /etc/fstab; then
        info "Adding automount entry to /etc/fstab..."
        log "Adding automount entry to /etc/fstab"
        
        # Add the entry to fstab
        echo "$server:$share $mount_point nfs $options 0 0" | sudo tee -a /etc/fstab > /dev/null
        check_success "Added mount entry to /etc/fstab" "Failed to add mount entry to /etc/fstab"
    else
        success "Mount entry already exists in /etc/fstab"
        log "Mount entry already exists in /etc/fstab"
    fi
    
    # Try to mount now
    info "Mounting $server:$share to $mount_point..."
    log "Mounting $server:$share to $mount_point"
    
    sudo mount "$mount_point"
    if mount | grep -q "$mount_point"; then
        success "Successfully mounted $server:$share to $mount_point"
        log "Successfully mounted $server:$share to $mount_point"
    else
        warning "Failed to mount $server:$share to $mount_point. Will retry on system startup."
        log "Failed to mount $server:$share to $mount_point"
    fi
}

# Function to configure automounting for an SMB share
configure_smb_mount() {
    local name=$1
    local server=$2
    local share=$3
    local mount_point=$4
    local options=$5
    
    info "Configuring SMB mount for $name..."
    log "Configuring SMB mount for $name at $mount_point"
    
    # Ensure mount point exists
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
        if [ -n "$OPERATOR_USER" ] && id "$OPERATOR_USER" &>/dev/null; then
            chown "$OPERATOR_USER" "$mount_point"
        fi
        success "Created mount point: $mount_point"
        log "Created mount point: $mount_point"
    fi
    
    # Create the mount entry in /etc/fstab
    if ! grep -q "//$server/$share" /etc/fstab; then
        info "Adding automount entry to /etc/fstab..."
        log "Adding automount entry to /etc/fstab"
        
        # Add the entry to fstab
        echo "//$server/$share $mount_point smbfs $options 0 0" | sudo tee -a /etc/fstab > /dev/null
        check_success "Added mount entry to /etc/fstab" "Failed to add mount entry to /etc/fstab"
    else
        success "Mount entry already exists in /etc/fstab"
        log "Mount entry already exists in /etc/fstab"
    fi
    
    # Try to mount now
    info "Mounting //$server/$share to $mount_point..."
    log "Mounting //$server/$share to $mount_point"
    
    sudo mount "$mount_point"
    if mount | grep -q "$mount_point"; then
        success "Successfully mounted //$server/$share to $mount_point"
        log "Successfully mounted //$server/$share to $mount_point"
    else
        warning "Failed to mount //$server/$share to $mount_point. Will retry on system startup."
        log "Failed to mount //$server/$share to $mount_point"
    fi
}

# Function to configure automounting for an AFP share
configure_afp_mount() {
    local name=$1
    local server=$2
    local share=$3
    local mount_point=$4
    local options=$5
    
    info "Configuring AFP mount for $name..."
    log "Configuring AFP mount for $name at $mount_point"
    
    # Ensure mount point exists
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
        if [ -n "$OPERATOR_USER" ] && id "$OPERATOR_USER" &>/dev/null; then
            chown "$OPERATOR_USER" "$mount_point"
        fi
        success "Created mount point: $mount_point"
        log "Created mount point: $mount_point"
    fi
    
    # AFP is being deprecated by Apple, so we'll use mount_afp directly
    if ! mount | grep -q "afp://$server/$share"; then
        info "Mounting AFP share $server:$share..."
        log "Mounting AFP share $server:$share"
        
        # Mount the AFP share using mount_afp
        sudo mount_afp "afp://$server/$share" "$mount_point"
        check_success "Mounted AFP share $server:$share" "Failed to mount AFP share $server:$share"
    else
        success "AFP share $server:$share is already mounted"
        log "AFP share $server:$share is already mounted"
    fi
    
    # For automounting at boot, we need to use autofs or a startup script
    info "Creating automount script for AFP share..."
    log "Creating automount script for AFP share"
    
    # Create a startup script
    local AUTO_SCRIPT="$HOME/scripts/mount_${name}_afp.sh"
    cat > "$AUTO_SCRIPT" << EOL
#!/bin/bash
# Script to automount AFP share $name

# Check if share is already mounted
if ! mount | grep -q "$mount_point"; then
    echo "Mounting AFP share $server:$share to $mount_point..."
    sudo mount_afp "afp://$server/$share" "$mount_point"
    if [ \$? -eq 0 ]; then
        echo "Successfully mounted AFP share"
    else
        echo "Failed to mount AFP share"
    fi
else
    echo "AFP share is already mounted"
fi
EOL
    chmod +x "$AUTO_SCRIPT"
    
    # Create a LaunchAgent to run this script at startup
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.user.mount_${name}_afp.plist" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.mount_${name}_afp</string>
    <key>ProgramArguments</key>
    <array>
        <string>$AUTO_SCRIPT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>$HOME/logs/mount_${name}_afp.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/logs/mount_${name}_afp.log</string>
</dict>
</plist>
EOL
    
    # Load the LaunchAgent
    launchctl load "$HOME/Library/LaunchAgents/com.user.mount_${name}_afp.plist"
    check_success "Created and loaded AFP automount script" "Failed to create AFP automount script"
}

# Process each mount based on the mount type
info "Processing NAS mounts from configuration..."
log "Processing NAS mounts from configuration"

# Get the list of mounts
MOUNT_COUNT=$(get_config '.nas.mounts | length')

if [ "$MOUNT_COUNT" -eq 0 ]; then
    warning "No NAS mounts defined in configuration"
    log "No NAS mounts defined in configuration"
else
    for i in $(seq 0 $((MOUNT_COUNT - 1))); do
        # Extract mount details
        NAME=$(get_config ".nas.mounts[$i].name")
        SERVER=$(get_config ".nas.mounts[$i].server")
        SHARE=$(get_config ".nas.mounts[$i].share")
        MOUNT_POINT=$(get_config ".nas.mounts[$i].mount_point")
        OPTIONS=$(get_config ".nas.mounts[$i].options")
        
        # Validate mount details
        if [ -z "$NAME" ] || [ -z "$SERVER" ] || [ -z "$SHARE" ] || [ -z "$MOUNT_POINT" ]; then
            warning "Incomplete mount configuration for index $i - skipping"
            log "Incomplete mount configuration for index $i - skipping"
            continue
        fi
        
        # Substitute user home paths if needed
        MOUNT_POINT="${MOUNT_POINT/#\~/$HOME}"
        MOUNT_POINT="${MOUNT_POINT/#\$HOME/$HOME}"
        
        # Substitute operator user if needed
        if [ -n "$OPERATOR_USER" ]; then
            MOUNT_POINT="${MOUNT_POINT//\$OPERATOR_USER/$OPERATOR_USER}"
            OPERATOR_HOME="/Users/$OPERATOR_USER"
            MOUNT_POINT="${MOUNT_POINT/#\~/$OPERATOR_HOME}"
        fi
        
        # Use default options if not specified
        if [ -z "$OPTIONS" ]; then
            case "$NAS_MOUNT_TYPE" in
                "nfs")
                    OPTIONS="rw,resvport,locallocks"
                    ;;
                "smb")
                    OPTIONS="rw,nounix,sec=ntlmssp"
                    ;;
                "afp")
                    OPTIONS="rw"
                    ;;
                *)
                    OPTIONS="rw"
                    ;;
            esac
        fi
        
        # Configure the mount based on type
        case "$NAS_MOUNT_TYPE" in
            "nfs")
                configure_nfs_mount "$NAME" "$SERVER" "$SHARE" "$MOUNT_POINT" "$OPTIONS"
                ;;
            "smb")
                configure_smb_mount "$NAME" "$SERVER" "$SHARE" "$MOUNT_POINT" "$OPTIONS"
                ;;
            "afp")
                configure_afp_mount "$NAME" "$SERVER" "$SHARE" "$MOUNT_POINT" "$OPTIONS"
                ;;
            *)
                warning "Unsupported mount type: $NAS_MOUNT_TYPE - defaulting to NFS"
                log "Unsupported mount type: $NAS_MOUNT_TYPE - defaulting to NFS"
                configure_nfs_mount "$NAME" "$SERVER" "$SHARE" "$MOUNT_POINT" "$OPTIONS"
                ;;
        esac
    done
fi

# Create NAS monitoring script
header "Setting Up NAS Monitoring"
log "Setting up NAS monitoring"

info "Creating NAS monitoring script..."
log "Creating NAS monitoring script"

# Create the monitoring script
NAS_MONITOR_SCRIPT="$HOME/scripts/nas_monitor.sh"

cat > "$NAS_MONITOR_SCRIPT" << EOL
#!/bin/bash

# NAS monitoring script
LOG_FILE="$HOME/logs/nas_monitor.log"
echo "\$(date): Running NAS mount check" >> "\$LOG_FILE"

# Check all configured NAS mounts
EOL

# Add checks for each mount point
for i in $(seq 0 $((MOUNT_COUNT - 1))); do
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
    if [ -n "$OPERATOR_USER" ]; then
        MOUNT_POINT="${MOUNT_POINT//\$OPERATOR_USER/$OPERATOR_USER}"
        OPERATOR_HOME="/Users/$OPERATOR_USER"
        MOUNT_POINT="${MOUNT_POINT/#\~/$OPERATOR_HOME}"
    fi
    
    # Add check to the script
    cat >> "$NAS_MONITOR_SCRIPT" << EOL
# Check $NAME mount
if mountpoint -q "$MOUNT_POINT"; then
    echo "\$(date): $NAME is mounted at $MOUNT_POINT" >> "\$LOG_FILE"
    
    # Check if we can write to the mount
    if touch "$MOUNT_POINT/.nas_monitor_test" 2>/dev/null; then
        echo "\$(date): $NAME is writable" >> "\$LOG_FILE"
        rm "$MOUNT_POINT/.nas_monitor_test"
    else
        echo "\$(date): $NAME is not writable" >> "\$LOG_FILE"
        # Send alert
    fi
else
    echo "\$(date): $NAME is NOT mounted at $MOUNT_POINT" >> "\$LOG_FILE"
    
    # Try to remount
    echo "\$(date): Attempting to remount $NAME..." >> "\$LOG_FILE"
    sudo mount "$MOUNT_POINT" >> "\$LOG_FILE" 2>&1
    
    # Check if remount was successful
    if mountpoint -q "$MOUNT_POINT"; then
        echo "\$(date): Successfully remounted $NAME" >> "\$LOG_FILE"
    else
        echo "\$(date): Failed to remount $NAME" >> "\$LOG_FILE"
        # Send alert
    fi
fi

EOL
done

# Add log rotation to the script
cat >> "$NAS_MONITOR_SCRIPT" << EOL
# Rotate log file if too large (> 1MB)
if [ -f "\$LOG_FILE" ] && [ \$(stat -f%z "\$LOG_FILE") -gt 1048576 ]; then
    mv "\$LOG_FILE" "\$LOG_FILE.\$(date +%Y%m%d)"
    touch "\$LOG_FILE"
    echo "\$(date): Log file rotated" >> "\$LOG_FILE"
fi
EOL

chmod +x "$NAS_MONITOR_SCRIPT"
check_success "NAS monitoring script created" "Failed to create NAS monitoring script"

# Create LaunchAgent for NAS monitoring
info "Creating LaunchAgent for NAS monitoring..."
log "Creating LaunchAgent for NAS monitoring"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.user.nas_monitor.plist" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.nas_monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NAS_MONITOR_SCRIPT</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/logs/nas_monitor_out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/logs/nas_monitor_err.log</string>
</dict>
</plist>
EOL

# Load the NAS monitoring LaunchAgent
info "Loading NAS monitoring LaunchAgent..."
log "Loading NAS monitoring LaunchAgent"
launchctl load "$HOME/Library/LaunchAgents/com.user.nas_monitor.plist"
check_success "NAS monitoring service started" "Failed to start NAS monitoring service"

# Final message
header "NAS Setup Completed"
log "NAS setup completed"

info "Your NAS mounts have been configured with the following:"
for i in $(seq 0 $((MOUNT_COUNT - 1))); do
    NAME=$(get_config ".nas.mounts[$i].name")
    SERVER=$(get_config ".nas.mounts[$i].server")
    SHARE=$(get_config ".nas.mounts[$i].share")
    MOUNT_POINT=$(get_config ".nas.mounts[$i].mount_point")
    
    # Skip if incomplete configuration
    if [ -z "$NAME" ] || [ -z "$SERVER" ] || [ -z "$SHARE" ] || [ -z "$MOUNT_POINT" ]; then
        continue
    fi
    
    info "  - $NAME: $SERVER:$SHARE mounted at $MOUNT_POINT"
done
info "  - NAS monitoring enabled with hourly checks"
info "  - Automount configured to persist through reboots"

success "NAS setup completed successfully!"
log "NAS setup completed successfully!"

# Return success
exit 0