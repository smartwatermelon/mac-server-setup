#!/bin/bash

# Bootstrap Script for Mac Mini M2 Server Setup
# Purpose: Initial bootstrap to set up environment and clone the setup repository

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

# Create a log directory and file
mkdir -p "$HOME/logs"
LOGFILE="$HOME/logs/bootstrap.log"
touch "$LOGFILE"

# Function to log messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" >> "$LOGFILE"
}

header "Mac Mini M2 Server Bootstrap"
info "This script will prepare your Mac Mini for automated setup."
log "Bootstrap process started"

# Repository information
REPO_OWNER="smartwatermelon"
REPO_NAME="mac-server-setup"
REPO_URL="https://github.com/$REPO_OWNER/$REPO_NAME.git"
# REPO_BRANCH="main"    # unused?

# Local setup directory
SETUP_DIR="$HOME/mac-server-setup"

# Check for Xcode Command Line Tools
info "Checking for Xcode Command Line Tools..."
log "Checking for Xcode Command Line Tools"

if xcode-select -p &>/dev/null; then
    success "Xcode Command Line Tools are installed"
    log "Xcode Command Line Tools are installed"
else
    info "Installing Xcode Command Line Tools..."
    log "Installing Xcode Command Line Tools"

    # Start installation in the background
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

    # Find the latest version
    PROD=$(softwareupdate -l | grep "\*.*Command Line" | sort | tail -n 1 | sed 's/^[^C]* //')

    # Install it
    softwareupdate -i "$PROD" --verbose

    # Clean up
    rm /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

    if xcode-select -p &>/dev/null; then
        success "Xcode Command Line Tools installed successfully"
        log "Xcode Command Line Tools installed successfully"
    else
        error "Failed to install Xcode Command Line Tools"
        log "Failed to install Xcode Command Line Tools"
        exit 1
    fi
fi

# Install Homebrew if not installed
info "Checking for Homebrew..."
log "Checking for Homebrew"

if command -v brew &>/dev/null; then
    success "Homebrew is already installed"
    log "Homebrew is already installed"
else
    info "Installing Homebrew..."
    log "Installing Homebrew"

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH
    if [[ $(uname -m) == 'arm64' ]]; then
        # shellcheck disable=SC2016
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        # shellcheck disable=SC2016
        echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "$HOME/.zprofile"
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if command -v brew &>/dev/null; then
        success "Homebrew installed successfully"
        log "Homebrew installed successfully"
    else
        error "Failed to install Homebrew"
        log "Failed to install Homebrew"
        exit 1
    fi
fi

# Install Git and other essential tools
info "Installing essential tools..."
log "Installing essential tools"

if brew install git; then
    success "Git installed successfully"
    log "Git installed successfully"
else
    error "Failed to install Git"
    log "Failed to install Git"
    exit 1
fi

# Install yq for YAML parsing
if brew install yq; then
    success "yq installed successfully"
    log "yq installed successfully"
else
    error "Failed to install yq"
    log "Failed to install yq"
    exit 1
fi

# Setup SSH keys for GitHub access
info "Setting up SSH keys for GitHub access..."
log "Setting up SSH keys for GitHub access"

# Check if SSH key already exists
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    # Generate a new SSH key
    if ssh-keygen -t ed25519 -C "mac-mini-server" -f "$HOME/.ssh/id_ed25519" -N ""; then
        success "SSH key generated successfully"
        log "SSH key generated successfully"
    else
        error "Failed to generate SSH key"
        log "Failed to generate SSH key"
        exit 1
    fi

    # Start the SSH agent
    eval "$(ssh-agent -s)"

    # Add the key to the agent
    ssh-add "$HOME/.ssh/id_ed25519"

    # Display the public key
    info "Please add the following public key to your GitHub repository deploy keys:"
    echo ""
    cat "$HOME/.ssh/id_ed25519.pub"
    echo ""
    info "After adding the key to GitHub, press Enter to continue..."
    read -n1 -sr
else
    success "SSH key already exists"
    log "SSH key already exists"
fi

# Clone the setup repository
info "Cloning the setup repository..."
log "Cloning the setup repository from $REPO_URL"

# Remove existing directory if it exists
if [ -d "$SETUP_DIR" ]; then
    info "Removing existing setup directory..."
    rm -rf "$SETUP_DIR"
fi

# Try cloning with HTTPS first (more likely to work without configuration)
if ! git clone "https://github.com/$REPO_OWNER/$REPO_NAME.git" "$SETUP_DIR"; then
    warning "HTTPS clone failed, trying SSH..."
    log "HTTPS clone failed, trying SSH"

    # Try with SSH
    if ! git clone "git@github.com:$REPO_OWNER/$REPO_NAME.git" "$SETUP_DIR"; then
        error "Failed to clone repository"
        log "Failed to clone repository"
        exit 1
    fi
fi

success "Repository cloned successfully to $SETUP_DIR"
log "Repository cloned successfully to $SETUP_DIR"

# Make scripts executable
info "Making scripts executable..."
log "Making scripts executable"

chmod +x "$SETUP_DIR/setup.sh"
chmod +x "$SETUP_DIR/test_harness.sh"
chmod +x "$SETUP_DIR/scripts/"*.sh

success "Scripts are now executable"
log "Scripts are now executable"

# Final instructions
header "Bootstrap Completed"
log "Bootstrap completed successfully"

info "Your Mac Mini has been bootstrapped for automated setup."
info "To begin the setup process, run the following command:"
echo ""
echo "cd $SETUP_DIR && ./setup.sh"
echo ""
info "This will start the automated setup process."

success "Bootstrap completed successfully!"
log "Bootstrap process completed successfully"

# Offer to start the setup process
read -p "Would you like to start the setup process now? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    info "Starting setup process..."
    log "Starting setup process directly after bootstrap"
    cd "$SETUP_DIR" && ./setup.sh
else
    info "Setup process not started. You can run it later with the command above."
    log "Setup process not started automatically"
fi

exit 0
