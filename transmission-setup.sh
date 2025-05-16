#!/bin/bash
#
# transmission-setup.sh - Transmission BitTorrent client setup script for Mac Mini M2 'TILSIT' server
#
# This script sets up Transmission BitTorrent client in a Docker container
#
# Usage: ./transmission-setup.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude
# Version: 1.0
# Created: 2025-05-13

# Exit on error
set -e

# Configuration variables - adjust as needed
export LOG_DIR; LOG_DIR="$HOME/.local/state" # XDG_STATE_HOME
LOG_FILE="$LOG_DIR/tilsit-apps.log"
TRANSMISSION_CONFIG_DIR="${HOME}/Docker/transmission/config"
TRANSMISSION_DOWNLOADS_DIR="${HOME}/Docker/transmission/downloads"
TRANSMISSION_WATCH_DIR="${HOME}/Docker/transmission/watch"
TRANSMISSION_TIMEZONE="America/Los_Angeles" # Adjust to your timezone
TRANSMISSION_USERNAME="tilsit"
TRANSMISSION_PASSWORD="tilsit_password" # Change this to a secure password!

# Parse command line arguments
FORCE=false

for arg in "$@"; do
  case $arg in
    --force)
      FORCE=true
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

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  sudo touch "$LOG_FILE"
  sudo chmod 644 "$LOG_FILE"
fi

# Print header
section "Setting Up Transmission BitTorrent Client"
log "Running as user: $(whoami)"
log "Date: $(date)"

# Confirm operation if not forced
if [ "$FORCE" = false ]; then
  read -p "This script will set up Transmission BitTorrent client in a Docker container. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
  
  # Ask for password change if using default
  if [ "$TRANSMISSION_PASSWORD" = "tilsit_password" ]; then
    echo "The default password 'tilsit_password' is insecure."
    read -p "Would you like to set a different password? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      read -srp "Enter new password: " NEW_PASSWORD
      echo
      if [ -n "$NEW_PASSWORD" ]; then
        TRANSMISSION_PASSWORD="$NEW_PASSWORD"
        log "Custom password set"
      else
        log "No password provided, using default"
      fi
    else
      log "Using default password"
    fi
  fi
fi

# Check if Docker is running
section "Checking Docker"
if ! docker info &>/dev/null; then
  log "Docker is not running. Please start Docker Desktop first."
  exit 1
fi
log "Docker is running"

# Create Docker network if it doesn't exist
section "Setting Up Docker Network"
if ! docker network inspect tilsit-network &>/dev/null 2>&1; then
  log "Creating Docker network: tilsit-network"
  docker network create tilsit-network
  check_success "Docker network creation"
else
  log "Docker network tilsit-network already exists"
fi

# Create Transmission directories
section "Setting Up Transmission Directories"
for DIR in "$TRANSMISSION_CONFIG_DIR" "$TRANSMISSION_DOWNLOADS_DIR" "$TRANSMISSION_WATCH_DIR"; do
  if [ ! -d "$DIR" ]; then
    log "Creating directory: $DIR"
    mkdir -p "$DIR"
    check_success "Directory creation: $DIR"
  else
    log "Directory already exists: $DIR"
  fi
done

# Check if Transmission container is already running
section "Setting Up Transmission Container"
if docker ps -a --format '{{.Names}}' | grep -q "transmission"; then
  log "Transmission container already exists"
  
  # Check if it's running
  if ! docker ps --format '{{.Names}}' | grep -q "transmission"; then
    log "Starting existing Transmission container"
    docker start transmission
    check_success "Transmission container start"
  else
    log "Transmission container is already running"
  fi
else
  log "Creating and starting Transmission container"
  
  # Run the docker command
  docker run -d \
    --name=transmission \
    --network=tilsit-network \
    --restart=unless-stopped \
    -e TZ="$TRANSMISSION_TIMEZONE" \
    -e PUID="$(id -u)" \
    -e PGID="$(id -g)" \
    -e USER="$TRANSMISSION_USERNAME" \
    -e PASS="$TRANSMISSION_PASSWORD" \
    -p 9091:9091 \
    -p 51413:51413 \
    -p 51413:51413/udp \
    -v "$TRANSMISSION_CONFIG_DIR":/config \
    -v "$TRANSMISSION_DOWNLOADS_DIR":/downloads \
    -v "$TRANSMISSION_WATCH_DIR":/watch \
    linuxserver/transmission:latest
  
  check_success "Transmission container creation"
fi

# Provide access instructions
section "Transmission Setup Complete"
log "Transmission BitTorrent client has been set up successfully"
log "Access your Transmission web interface at: http://localhost:9091"
log "If accessing from another device, use: http://$(hostname -I | awk '{print $1}'):9091"
log "Login with username: $TRANSMISSION_USERNAME and your password"

# Additional instructions
log "Additional steps you may want to take:"
log "1. Configure download settings in the web interface"
log "2. Add torrent files to the $TRANSMISSION_WATCH_DIR directory for automatic downloading"
log "3. Set up port forwarding on your router for better connectivity (port 51413)"

exit 0
