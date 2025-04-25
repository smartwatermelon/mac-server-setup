#!/bin/bash

# Initial Setup Script for Mac Mini M2
# Purpose: Configure system settings and install required software

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
LOGFILE="$LOG_DIR/initial_setup.log"
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

# Ensure yq is installed for YAML parsing
if ! command -v yq &> /dev/null; then
    # Install Homebrew first if not installed
    if ! command -v brew &> /dev/null; then
        info "Installing Homebrew..."
        log "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [[ $(uname -m) == 'arm64' ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> $HOME/.zprofile
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            echo 'eval "$(/usr/local/bin/brew shellenv)"' >> $HOME/.zprofile
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        check_success "Homebrew installation" "Homebrew installation failed"
    fi
    
    info "Installing yq for YAML parsing..."
    log "Installing yq for YAML parsing..."
    brew install yq
    check_success "yq installation" "yq installation failed"
fi

# Function to get configuration values
get_config() {
    yq eval "$1" "$CONFIG_FILE"
}

header "Mac Mini M2 Initial Setup"
info "This script will perform initial system configuration and install required software."
log "Initial setup started"

# Set computer name from configuration
HOSTNAME=$(get_config '.system.hostname')
info "Setting computer name to $HOSTNAME..."
log "Setting computer name to $HOSTNAME..."
sudo scutil --set ComputerName "$HOSTNAME"
sudo scutil --set HostName "$HOSTNAME"
sudo scutil --set LocalHostName "$HOSTNAME"
check_success "Hostname setting" "Hostname setting failed"

# Create users if they don't exist
header "User Account Setup"
log "Setting up user accounts"

# Get user configurations
ADMIN_USER=$(get_config '.system.users.admin.name')
OPERATOR_USER=$(get_config '.system.users.operator.name')

# Check if operator user exists and create if not
if ! dscl . -list /Users | grep -q "^$OPERATOR_USER$"; then
    info "Creating operator user: $OPERATOR_USER..."
    log "Creating operator user: $OPERATOR_USER..."
    
    # Generate a random password
    OPERATOR_PASSWORD=$(openssl rand -base64 12)
    
    # Create the user
    sudo dscl . -create /Users/$OPERATOR_USER
    sudo dscl . -create /Users/$OPERATOR_USER UserShell /bin/bash
    sudo dscl . -create /Users/$OPERATOR_USER RealName "Server Operator"
    sudo dscl . -create /Users/$OPERATOR_USER UniqueID 501
    sudo dscl . -create /Users/$OPERATOR_USER PrimaryGroupID 20
    sudo dscl . -create /Users/$OPERATOR_USER NFSHomeDirectory /Users/$OPERATOR_USER
    sudo dscl . -passwd /Users/$OPERATOR_USER $OPERATOR_PASSWORD
    
    # Create home directory
    sudo createhomedir -c -u $OPERATOR_USER
    
    # Show the generated password (would be better to store this securely)
    info "Operator user created with password: $OPERATOR_PASSWORD"
    info "PLEASE RECORD THIS PASSWORD IN A SECURE LOCATION"
    log "Operator user created (password not logged for security)"
    
    check_success "Operator user creation" "Operator user creation failed"
else
    success "Operator user already exists"
    log "Operator user already exists, no action needed"
fi

# Install Rosetta 2 for compatibility with Intel-based apps
info "Installing Rosetta 2..."
log "Installing Rosetta 2..."
/usr/sbin/softwareupdate --install-rosetta --agree-to-license
check_success "Rosetta 2 installation" "Rosetta 2 installation failed"

# Install Homebrew if not already installed
if ! command -v brew &> /dev/null; then
    info "Installing Homebrew..."
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ $(uname -m) == 'arm64' ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> $HOME/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        echo 'eval "$(/usr/local/bin/brew shellenv)"' >> $HOME/.zprofile
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    check_success "Homebrew installation" "Homebrew installation failed"
fi

# Update Homebrew and upgrade installed formulae
info "Updating Homebrew..."
log "Updating Homebrew..."
brew update
brew upgrade
check_success "Homebrew update" "Homebrew update failed"

# Install Homebrew packages from configuration
header "Installing Software Packages"
log "Installing software packages from configuration"

# Install CLI tools (formulae)
CLI_TOOLS=$(get_config '.installation.packages.cli_tools[] | select(.)')
if [ -n "$CLI_TOOLS" ]; then
    info "Installing CLI tools from Homebrew..."
    log "Installing CLI tools from Homebrew..."
    
    # Create a temporary file with the list of packages
    FORMULA_LIST=$(mktemp)
    echo "$CLI_TOOLS" > "$FORMULA_LIST"
    
    # Install all packages at once
    brew install $(cat "$FORMULA_LIST") || warning "Some CLI tools failed to install. Check logs for details."
    log "CLI tools installation command executed"
    
    # Cleanup
    rm "$FORMULA_LIST"
else
    warning "No CLI tools specified in configuration"
    log "No CLI tools specified in configuration"
fi

# Install GUI applications (casks)
CASK_APPS=$(get_config '.installation.packages.cask_apps[] | select(.)')
if [ -n "$CASK_APPS" ]; then
    info "Installing GUI applications from Homebrew Cask..."
    log "Installing GUI applications from Homebrew Cask..."
    
    # Create a temporary file with the list of casks
    CASK_LIST=$(mktemp)
    echo "$CASK_APPS" > "$CASK_LIST"
    
    # Install all casks at once
    brew install --cask $(cat "$CASK_LIST") || warning "Some Cask apps failed to install. Check logs for details."
    log "Cask apps installation command executed"
    
    # Cleanup
    rm "$CASK_LIST"
else
    warning "No GUI applications specified in configuration"
    log "No GUI applications specified in configuration"
fi

# Install Mas (Mac App Store CLI) for installing Mac App Store apps
info "Installing Mas CLI..."
log "Installing Mas CLI..."
brew install mas
check_success "Mas installation" "Mas installation failed"

# Check if user is signed in to Mac App Store
mas_signin_status=$(mas account 2>&1)
if [[ "$mas_signin_status" == "Not signed in" ]]; then
    warning "You are not signed in to the Mac App Store. Some applications may not install."
    log "Not signed in to Mac App Store"
else
    success "Signed into Mac App Store as $mas_signin_status"
    log "Signed into Mac App Store as $mas_signin_status"
    
    # Install Mac App Store apps if specified in config
    MAS_APPS=$(get_config '.installation.packages.mas_apps[] | select(.)')
    if [ -n "$MAS_APPS" ]; then
        info "Installing Mac App Store applications..."
        log "Installing Mac App Store applications..."
        
        # Parse and install each app
        while IFS= read -r app_info; do
            app_id=$(echo $app_info | cut -d':' -f2)
            app_name=$(echo $app_info | cut -d':' -f1)
            
            info "Installing $app_name from Mac App Store..."
            mas install $app_id
            check_success "$app_name installation" "$app_name installation failed"
        done <<< "$MAS_APPS"
    else
        info "No Mac App Store apps specified in configuration"
        log "No Mac App Store apps specified in configuration"
    fi
fi

# Disable sleep and power management for server use
header "Configuring System Settings"
log "Configuring system settings for server use"

info "Configuring power management settings for server use..."
log "Configuring power management settings for server use..."
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a displaysleep 60
sudo pmset -a womp 1  # Wake for network access
check_success "Power management configuration" "Power management configuration failed"

# Configure automatic updates
info "Setting up automatic updates..."
log "Setting up automatic updates..."
sudo softwareupdate --schedule on
defaults write com.apple.SoftwareUpdate AutomaticDownload -bool true
defaults write com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
defaults write com.apple.commerce AutoUpdate -bool true
check_success "Automatic updates configuration" "Automatic updates configuration failed"

# Set up shell environment for both users
header "Setting Up Shell Environment"
log "Setting up shell environment"

# Function to set up bash environment for a user
setup_bash_env() {
    local user=$1
    local home_dir="/Users/$user"
    
    info "Setting up bash environment for $user..."
    log "Setting up bash environment for $user..."
    
    # Set up .bash_profile
    if [ ! -f "$home_dir/.bash_profile" ]; then
        sudo -u $user bash -c "cat > $home_dir/.bash_profile << 'EOL'
# Homebrew
if [[ \$(uname -m) == 'arm64' ]]; then
    eval \"\$(/opt/homebrew/bin/brew shellenv)\"
else
    eval \"\$(/usr/local/bin/brew shellenv)\"
fi

# Path additions
export PATH=\"/usr/local/bin:/usr/local/sbin:\$PATH\"

# Load bash completion
[[ -r \"/opt/homebrew/etc/profile.d/bash_completion.sh\" ]] && . \"/opt/homebrew/etc/profile.d/bash_completion.sh\"
[[ -r \"/usr/local/etc/profile.d/bash_completion.sh\" ]] && . \"/usr/local/etc/profile.d/bash_completion.sh\"

# Liquid Prompt - if installed
if [ -f \"/opt/homebrew/share/liquidprompt/liquidprompt\" ]; then
    source /opt/homebrew/share/liquidprompt/liquidprompt
elif [ -f \"/usr/local/share/liquidprompt/liquidprompt\" ]; then
    source /usr/local/share/liquidprompt/liquidprompt
fi

# History settings
export HISTSIZE=10000
export HISTFILESIZE=10000
export HISTCONTROL=ignoreboth:erasedups
shopt -s histappend

# Better ls colors
export CLICOLOR=1
export LSCOLORS=ExFxBxDxCxegedabagacad

# Aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Import local settings if they exist
if [ -f \"\$HOME/.bash_local\" ]; then
    source \"\$HOME/.bash_local\"
fi
EOL"
        success "Created .bash_profile for $user"
        log "Created .bash_profile for $user"
    else
        warning ".bash_profile already exists for $user, not overwriting"
        log ".bash_profile already exists for $user, not overwriting"
    fi
    
    # Set up .bashrc
    if [ ! -f "$home_dir/.bashrc" ]; then
        sudo -u $user bash -c "cat > $home_dir/.bashrc << 'EOL'
# Source .bash_profile
if [ -f \"\$HOME/.bash_profile\" ]; then
    source \"\$HOME/.bash_profile\"
fi
EOL"
        success "Created .bashrc for $user"
        log "Created .bashrc for $user"
    else
        warning ".bashrc already exists for $user, not overwriting"
        log ".bashrc already exists for $user, not overwriting"
    fi
}

# Create bash environment for our operator user
if id "$OPERATOR_USER" &>/dev/null; then
    setup_bash_env "$OPERATOR_USER"
fi

# Set newer bash as default shell if installed (for current user)
if command -v brew &> /dev/null && [ -f "$(brew --prefix)/bin/bash" ]; then
    BREW_BASH="$(brew --prefix)/bin/bash"
    if ! grep -q "$BREW_BASH" /etc/shells; then
        info "Adding Homebrew bash to /etc/shells..."
        log "Adding Homebrew bash to /etc/shells..."
        echo "$BREW_BASH" | sudo tee -a /etc/shells > /dev/null
    fi
    
    info "Setting bash from Homebrew as default shell for current user..."
    log "Setting bash from Homebrew as default shell for current user..."
    chsh -s "$BREW_BASH"
    check_success "Default shell configuration" "Default shell configuration failed"
    
    # Set for operator user too
    if id "$OPERATOR_USER" &>/dev/null; then
        info "Setting bash from Homebrew as default shell for $OPERATOR_USER..."
        log "Setting bash from Homebrew as default shell for $OPERATOR_USER..."
        sudo chsh -s "$BREW_BASH" "$OPERATOR_USER"
        check_success "Default shell configuration for $OPERATOR_USER" "Default shell configuration for $OPERATOR_USER failed"
    fi
fi

# Create necessary directories
header "Creating Directory Structure"
log "Creating directory structure"

# Function to create directories for a user
create_directories() {
    local user=$1
    local home_dir="/Users/$user"
    
    info "Creating standard directories for $user..."
    log "Creating standard directories for $user..."
    
    sudo -u $user mkdir -p "$home_dir/scripts"
    sudo -u $user mkdir -p "$home_dir/logs"
    sudo -u $user mkdir -p "$home_dir/backups"
    sudo -u $user mkdir -p "$home_dir/NAS"
    
    # Create Docker data directory if using containers
    local container_data_dir=$(get_config '.containers.data_dir')
    if [ -n "$container_data_dir" ]; then
        container_data_dir="${container_data_dir/#\~/$home_dir}"
        container_data_dir="${container_data_dir/#\$HOME/$home_dir}"
        
        # Create user-specific path if needed
        container_data_dir="${container_data_dir//\$OPERATOR_USER/$user}"
        container_data_dir="${container_data_dir//\$USER/$user}"
        
        sudo -u $user mkdir -p "$container_data_dir"
        sudo -u $user mkdir -p "$container_data_dir/config"
        sudo -u $user mkdir -p "$container_data_dir/data"
        
        success "Created Docker data directory: $container_data_dir"
        log "Created Docker data directory: $container_data_dir"
    fi
}

# Create directories for operator user
if id "$OPERATOR_USER" &>/dev/null; then
    create_directories "$OPERATOR_USER"
fi

# Create maintenance script
header "Setting Up System Maintenance"
log "Setting up system maintenance"

info "Creating maintenance script..."
log "Creating maintenance script..."
MAINTENANCE_SCRIPT="$HOME/scripts/maintenance.sh"

cat > "$MAINTENANCE_SCRIPT" << EOL
#!/bin/bash

# Weekly maintenance script
echo "Running system maintenance at \$(date)"

# Update Homebrew and all packages
brew update && brew upgrade && brew cleanup

# Update Mac OS software
softwareupdate -i -a

# Check disk space
df -h /

# Run periodic maintenance scripts
sudo periodic daily weekly monthly

# Clean system caches
sudo rm -rf /Library/Caches/*
rm -rf ~/Library/Caches/*

# Check if container runtime is running and restart if needed
if command -v colima &> /dev/null; then
    if ! colima status 2>/dev/null | grep -q "running"; then
        echo "Container runtime is not running. Attempting to start..."
        colima start --cpu \$(yq eval '.containers.configuration.cpu' \$(dirname \$0)/../config.yaml) \\
                     --memory \$(yq eval '.containers.configuration.memory' \$(dirname \$0)/../config.yaml) \\
                     --disk \$(yq eval '.containers.configuration.disk' \$(dirname \$0)/../config.yaml)
    else
        echo "Container runtime is running correctly."
    fi
fi

# Optional: Restart the system once a week
# sudo shutdown -r now
EOL
chmod +x "$MAINTENANCE_SCRIPT"
check_success "Maintenance script creation" "Maintenance script creation failed"

# Create a LaunchAgent for weekly maintenance
info "Creating LaunchAgent for weekly maintenance..."
log "Creating LaunchAgent for weekly maintenance..."
MAINTENANCE_SCHEDULE_DAY=$(get_config '.maintenance.system_updates.day')
MAINTENANCE_SCHEDULE_HOUR=$(get_config '.maintenance.system_updates.hour')

# Default to Monday 3AM if not specified
MAINTENANCE_SCHEDULE_DAY=${MAINTENANCE_SCHEDULE_DAY:-1}
MAINTENANCE_SCHEDULE_HOUR=${MAINTENANCE_SCHEDULE_HOUR:-3}

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.user.maintenance.plist" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.maintenance</string>
    <key>ProgramArguments</key>
    <array>
        <string>$MAINTENANCE_SCRIPT</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>$MAINTENANCE_SCHEDULE_DAY</integer>
        <key>Hour</key>
        <integer>$MAINTENANCE_SCHEDULE_HOUR</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/logs/maintenance.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/logs/maintenance.log</string>
</dict>
</plist>
EOL

# Create logs directory and file
mkdir -p "$HOME/logs"
touch "$HOME/logs/maintenance.log"
check_success "Maintenance LaunchAgent creation" "Maintenance LaunchAgent creation failed"

# Load the maintenance LaunchAgent
info "Loading maintenance LaunchAgent..."
log "Loading maintenance LaunchAgent..."
launchctl load "$HOME/Library/LaunchAgents/com.user.maintenance.plist"
check_success "Maintenance LaunchAgent loading" "Maintenance LaunchAgent loading failed"

# Set up Docker environment with Colima
header "Setting Up Container Environment"
log "Setting up container environment"

info "Configuring Docker and container runtime..."
log "Configuring Docker and container runtime..."

# Get container configuration values
CONTAINER_RUNTIME=$(get_config '.containers.runtime')
CONTAINER_CPU=$(get_config '.containers.configuration.cpu')
CONTAINER_MEMORY=$(get_config '.containers.configuration.memory')
CONTAINER_DISK=$(get_config '.containers.configuration.disk')

# Ensure we have values, use defaults if not
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-"colima"}
CONTAINER_CPU=${CONTAINER_CPU:-2}
CONTAINER_MEMORY=${CONTAINER_MEMORY:-4}
CONTAINER_DISK=${CONTAINER_DISK:-100}

# Check if Docker is installed
if command -v docker &> /dev/null; then
    success "Docker is installed"
    log "Docker is installed"
else
    # Try to install Docker CLI
    info "Installing Docker CLI..."
    log "Installing Docker CLI..."
    brew install docker docker-compose docker-buildx
    check_success "Docker CLI installation" "Docker CLI installation failed"
fi

# Setup container runtime (Colima)
if [ "$CONTAINER_RUNTIME" = "colima" ]; then
    if ! command -v colima &> /dev/null; then
        info "Installing Colima container runtime..."
        log "Installing Colima container runtime..."
        brew install colima
        check_success "Colima installation" "Colima installation failed"
    fi
    
    # Start Colima (lightweight container runtime for macOS)
    info "Starting Colima container runtime..."
    log "Starting Colima container runtime..."
    colima start --cpu $CONTAINER_CPU --memory $CONTAINER_MEMORY --disk $CONTAINER_DISK
    check_success "Colima startup" "Colima startup failed"
    
    # Verify Docker is working
    info "Verifying Docker installation..."
    log "Verifying Docker installation..."
    docker version
    docker info
    check_success "Docker verification" "Docker verification failed"
fi

# Configure firewall if needed
FIREWALL_ENABLED=$(get_config '.network.firewall.enabled')
if [ "$FIREWALL_ENABLED" = "true" ]; then
    info "Configuring firewall..."
    log "Configuring firewall..."
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
    
    # Configure stealth mode if enabled
    STEALTH_MODE=$(get_config '.network.firewall.stealth_mode')
    if [ "$STEALTH_MODE" = "true" ]; then
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
    fi
    
    check_success "Firewall configuration" "Firewall configuration failed"
    
    # Add allowed services to firewall
    ALLOWED_SERVICES=$(get_config '.network.firewall.allowed_services[] | select(.)')
    if [ -n "$ALLOWED_SERVICES" ]; then
        for service in $ALLOWED_SERVICES; do
            case "$service" in
                "ssh")
                    info "Adding SSH to firewall exceptions..."
                    log "Adding SSH to firewall exceptions..."
                    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "/usr/sbin/sshd"
                    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "/usr/sbin/sshd"
                    ;;
                "http" | "https")
                    # Allow standard web ports
                    info "Adding ports 80 and 443 to firewall exceptions..."
                    log "Adding ports 80 and 443 to firewall exceptions..."
                    sudo /usr/sbin/ipfw add allow tcp from any to any 80
                    sudo /usr/sbin/ipfw add allow tcp from any to any 443
                    ;;
                "32400")
                    # Plex port
                    info "Adding Plex port 32400 to firewall exceptions..."
                    log "Adding Plex port 32400 to firewall exceptions..."
                    sudo /usr/sbin/ipfw add allow tcp from any to any 32400
                    ;;
                *)
                    # For any other service or port
                    if [[ "$service" =~ ^[0-9]+$ ]]; then
                        # If it's a numeric port
                        info "Adding port $service to firewall exceptions..."
                        log "Adding port $service to firewall exceptions..."
                        sudo /usr/sbin/ipfw add allow tcp from any to any $service
                    else
                        warning "Unknown service for firewall exception: $service"
                        log "Unknown service for firewall exception: $service"
                    fi
                    ;;
            esac
        done
    fi
fi

# Final message
header "Initial Setup Completed"
log "Initial setup completed"

info "Your Mac Mini has been configured with the following:"
info "  - Hostname: $HOSTNAME"
info "  - Software packages installed from Homebrew"
info "  - Automated maintenance scheduled"
info "  - Power settings optimized for server use"
if [ "$FIREWALL_ENABLED" = "true" ]; then
    info "  - Firewall configured with necessary exceptions"
fi
if [ "$CONTAINER_RUNTIME" = "colima" ]; then
    info "  - Container runtime (Colima) configured and running"
fi

success "Initial setup completed successfully!"
log "Initial setup completed successfully!"

# Return success
exit 0