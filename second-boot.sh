#!/bin/bash
#
# second-boot.sh - Secondary setup script for Mac Mini M2 'TILSIT' server
#
# This script handles:
# - Homebrew installation from the GitHub release package
# - Installation of formulae and casks
# - Setup of system paths and environment variables
# - Preparations for application installation
#
# Usage: ./second-boot.sh [--force] [--skip-homebrew] [--skip-packages]
#   --force: Skip all confirmation prompts
#   --skip-homebrew: Skip Homebrew installation/update
#   --skip-packages: Skip package installation
#
# Author: Claude
# Version: 1.1
# Created: 2025-05-13

# Exit on error
set -e

# Configuration variables
HOMEBREW_VERSION="4.5.2"
HOMEBREW_PKG_URL="https://github.com/Homebrew/brew/releases/download/${HOMEBREW_VERSION}/Homebrew-${HOMEBREW_VERSION}.pkg"
HOMEBREW_PKG_FILE="/tmp/Homebrew-${HOMEBREW_VERSION}.pkg"
export LOG_DIR; LOG_DIR="$HOME/.local/state" # XDG_STATE_HOME
LOG_FILE="$LOG_DIR/tilsit-setup.log"
FORMULAE_FILE="/Users/$(whoami)/formulae.txt"
CASKS_FILE="/Users/$(whoami)/casks.txt"

# Parse command line arguments
FORCE=false
SKIP_HOMEBREW=false
SKIP_PACKAGES=false

for arg in "$@"; do
  case $arg in
    --force)
      FORCE=true
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

# Function to log messages to both console and log file
log() {
  mkdir -p "$LOG_DIR"
  local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
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

# Disable LaunchAgent to prevent this from running again
disable_launchagent() {
  local launch_agent; launch_agent="/Users/$(whoami)/Library/LaunchAgents/com.tilsit.secondboot.plist"
  
  if [ -f "$launch_agent" ]; then
    log "Disabling second-boot LaunchAgent"
    launchctl unload "$launch_agent"
    mv "$launch_agent" "${launch_agent}.disabled"
    check_success "LaunchAgent disabled"
  fi
}

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  sudo touch "$LOG_FILE"
  sudo chmod 644 "$LOG_FILE"
fi

# Print header
section "Starting Second-Boot Setup for Mac Mini M2 'TILSIT' Server"
log "Running as user: $(whoami)"
log "Date: $(date)"
log "macOS Version: $(sw_vers -productVersion)"

# Confirm operation if not forced
if [ "$FORCE" = false ]; then
  read -p "This script will install Homebrew and packages on your Mac Mini server. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

# Check for required package lists
if [ ! -f "$FORMULAE_FILE" ]; then
  log "Error: Required formulae list not found at $FORMULAE_FILE"
  if [ "$FORCE" = false ]; then
    read -p "This is a critical error. Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log "Exiting due to missing formulae list"
      exit 1
    fi
  fi
fi

if [ ! -f "$CASKS_FILE" ]; then
  log "Error: Required casks list not found at $CASKS_FILE"
  if [ "$FORCE" = false ]; then
    read -p "This is a critical error. Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log "Exiting due to missing casks list"
      exit 1
    fi
  fi
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
    log "Downloading Homebrew package installer"
    curl -L -o "$HOMEBREW_PKG_FILE" "$HOMEBREW_PKG_URL"
    check_success "Homebrew package download"
    
    log "Installing Homebrew"
    sudo installer -pkg "$HOMEBREW_PKG_FILE" -target /
    check_success "Homebrew installation"
    
    # Clean up
    rm -f "$HOMEBREW_PKG_FILE"
    
    # Add Homebrew to path
    if [[ "$(uname -m)" == "arm64" ]]; then
      HOMEBREW_PREFIX="/opt/homebrew"
    else
      HOMEBREW_PREFIX="/usr/local"
    fi
    
    # Add to shell configuration files
    for SHELL_PROFILE in ~/.zprofile ~/.bash_profile ~/.profile; do
      if [ -f "$SHELL_PROFILE" ]; then
        # Only add if not already present
        if ! grep -q "HOMEBREW_PREFIX" "$SHELL_PROFILE"; then
          log "Adding Homebrew to $SHELL_PROFILE"
          echo -e '\n# Homebrew' >> "$SHELL_PROFILE"
          echo "eval \"\$(${HOMEBREW_PREFIX}/bin/brew shellenv)\"" >> "$SHELL_PROFILE"
        fi
      fi
    done
    
    # Apply to current session
    eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
    
    log "Homebrew installation completed"
    
    # Verify installation
    brew --version
    check_success "Homebrew verification"
  fi
fi

# Install packages
if [ "$SKIP_PACKAGES" = false ]; then
  section "Installing Packages"
  
  # Function to install formulae if not already installed
  install_formula() {
    if ! brew list "$1" &>/dev/null; then
      log "Installing formula: $1"
      brew install "$1"
      check_success "Formula installation: $1"
    else
      log "Formula already installed: $1"
    fi
  }
  
  # Function to install casks if not already installed
  install_cask() {
    if ! brew list --cask "$1" &>/dev/null 2>&1; then
      log "Installing cask: $1"
      brew install --cask "$1"
      check_success "Cask installation: $1"
    else
      log "Cask already installed: $1"
    fi
  }
  
  # Install formulae from list
  if [ -f "$FORMULAE_FILE" ]; then
    log "Installing formulae from $FORMULAE_FILE"
    while read -r formula; do
      [[ -z "$formula" || "$formula" == \#* ]] && continue
      install_formula "$formula"
    done < "$FORMULAE_FILE"
  else
    log "Formulae list not found, skipping formula installations"
  fi
  
  # Install casks from list
  if [ -f "$CASKS_FILE" ]; then
    log "Installing casks from $CASKS_FILE"
    while read -r cask; do
      [[ -z "$cask" || "$cask" == \#* ]] && continue
      install_cask "$cask"
    done < "$CASKS_FILE"
  else
    log "Casks list not found, skipping cask installations"
  fi
  
  # Cleanup after installation
  log "Cleaning up Homebrew files"
  brew cleanup
  check_success "Homebrew cleanup"
fi

# Create application setup directory
section "Preparing Application Setup"
APP_SETUP_DIR="/Users/$(whoami)/app-setup"

if [ ! -d "$APP_SETUP_DIR" ]; then
  log "Creating application setup directory"
  mkdir -p "$APP_SETUP_DIR"
  check_success "App setup directory creation"
fi

# Copy application setup scripts from tilsit-setup directory if available
SETUP_DIR="$HOME/tilsit-setup"
if [ -d "$SETUP_DIR/scripts/app-setup" ]; then
  log "Copying application setup scripts from $SETUP_DIR/scripts/app-setup"
  cp "$SETUP_DIR/scripts/app-setup/"*.sh "$APP_SETUP_DIR/" 2>/dev/null
  chmod +x "$APP_SETUP_DIR/"*.sh 2>/dev/null
  check_success "Application scripts copy"
else
  log "No application setup scripts found in $SETUP_DIR/scripts/app-setup"
fi

# Disable the LaunchAgent to prevent this from running again
section "Finalizing Setup"
disable_launchagent

# Setup completed successfully
section "Second-Boot Setup Complete"
log "Homebrew and packages have been installed successfully"
log "For application setup, run the scripts in $APP_SETUP_DIR"

exit 0
