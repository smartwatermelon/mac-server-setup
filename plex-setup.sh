#!/bin/bash
#
# plex-setup.sh - Plex Media Server setup script for Mac Mini M2 'TILSIT' server
#
# This script sets up Plex Media Server in a Docker container
#
# Usage: ./plex-setup.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude
# Version: 1.0
# Created: 2025-05-13

# Exit on error
set -e

# Configuration variables - adjust as needed
LOG_FILE="/var/log/tilsit-apps.log"
PLEX_CLAIM_TOKEN="" # Get from https://www.plex.tv/claim/
PLEX_CONFIG_DIR="${HOME}/Docker/plex/config"
PLEX_MEDIA_DIR="/Volumes/MediaDrive" # Adjust to your media location
PLEX_TIMEZONE="America/Los_Angeles" # Adjust to your timezone

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
section "Setting Up Plex Media Server"
log "Running as user: $(whoami)"
log "Date: $(date)"

# Confirm operation if not forced
if [ "$FORCE" = false ]; then
  read -p "This script will set up Plex Media Server in a Docker container. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

# Check if Docker is running
section "Checking Docker"
if ! docker info &>/dev/null; then
  log "Docker is not running. Please start Docker Desktop first."
  exit 1
fi
log "Docker is running"

# Check if Plex claim token is set
if [ -z "$PLEX_CLAIM_TOKEN" ] && [ "$FORCE" = false ]; then
  log "Plex claim token is not set"
  echo "Please get a claim token from https://www.plex.tv/claim/"
  echo "It will expire after 4 minutes, so be ready to use it immediately"
  read -rp "Enter your Plex claim token: " PLEX_CLAIM_TOKEN
  
  if [ -z "$PLEX_CLAIM_TOKEN" ]; then
    log "No claim token provided, continuing without it"
    echo "You'll need to manually claim the server later"
  else
    log "Claim token provided"
  fi
fi

# Create Docker network if it doesn't exist
section "Setting Up Docker Network"
if ! docker network inspect tilsit-network &>/dev/null 2>&1; then
  log "Creating Docker network: tilsit-network"
  docker network create tilsit-network
  check_success "Docker network creation"
else
  log "Docker network tilsit-network already exists"
fi

# Create Plex configuration directory
section "Setting Up Plex Directories"
if [ ! -d "$PLEX_CONFIG_DIR" ]; then
  log "Creating Plex config directory: $PLEX_CONFIG_DIR"
  mkdir -p "$PLEX_CONFIG_DIR"
  check_success "Plex config directory creation"
else
  log "Plex config directory already exists"
fi

# Verify media directory exists
if [ ! -d "$PLEX_MEDIA_DIR" ]; then
  log "Warning: Media directory $PLEX_MEDIA_DIR does not exist"
  
  if [ "$FORCE" = false ]; then
    read -p "Create the media directory? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      log "Creating media directory: $PLEX_MEDIA_DIR"
      sudo mkdir -p "$PLEX_MEDIA_DIR"
      sudo chown "$(id -u)":"$(id -g)" "$PLEX_MEDIA_DIR"
      check_success "Media directory creation"
    else
      log "Using non-existent media directory, Plex may not function properly"
    fi
  else
    log "Creating media directory automatically: $PLEX_MEDIA_DIR"
    sudo mkdir -p "$PLEX_MEDIA_DIR"
    sudo chown "$(id -u)":"$(id -g)" "$PLEX_MEDIA_DIR"
    check_success "Media directory creation"
  fi
else
  log "Media directory exists: $PLEX_MEDIA_DIR"
fi

# Check if Plex container is already running
section "Setting Up Plex Container"
if docker ps -a --format '{{.Names}}' | grep -q "plex"; then
  log "Plex container already exists"
  
  # Check if it's running
  if ! docker ps --format '{{.Names}}' | grep -q "plex"; then
    log "Starting existing Plex container"
    docker start plex
    check_success "Plex container start"
  else
    log "Plex container is already running"
  fi
else
  log "Creating and starting Plex container"
  
  # Construct the docker run command
  DOCKER_CMD="docker run -d \
    --name=plex \
    --network=tilsit-network \
    --restart=unless-stopped \
    -e TZ=\"$PLEX_TIMEZONE\" \
    -e PUID=\"$(id -u)\" \
    -e PGID=\"$(id -g)\" \
    -e HOSTNAME=\"TILSIT-PLEX\" \
    -p 32400:32400/tcp \
    -p 3005:3005/tcp \
    -p 8324:8324/tcp \
    -p 32469:32469/tcp \
    -p 1900:1900/udp \
    -p 32410:32410/udp \
    -p 32412:32412/udp \
    -p 32413:32413/udp \
    -p 32414:32414/udp \
    -v \"$PLEX_CONFIG_DIR\":/config \
    -v \"$PLEX_MEDIA_DIR\":/media"
  
  # Add claim token if provided
  if [ -n "$PLEX_CLAIM_TOKEN" ]; then
    DOCKER_CMD="$DOCKER_CMD \
    -e PLEX_CLAIM=\"$PLEX_CLAIM_TOKEN\""
  fi
  
  # Add the image name
  DOCKER_CMD="$DOCKER_CMD \
    linuxserver/plex:latest"
  
  # Run the docker command
  eval "$DOCKER_CMD"
  check_success "Plex container creation"
fi

# Provide access instructions
section "Plex Setup Complete"
log "Plex Media Server has been set up successfully"
log "Access your Plex server at: http://localhost:32400/web"
log "If accessing from another device, use: http://$(hostname -I | awk '{print $1}'):32400/web"

# Provide claim instructions if token wasn't provided
if [ -z "$PLEX_CLAIM_TOKEN" ]; then
  log "Note: You'll need to claim your server manually when you first access it"
fi

# Additional steps
log "Additional steps you may want to take:"
log "1. Add media to your $PLEX_MEDIA_DIR directory"
log "2. Configure Plex libraries through the web interface"
log "3. Set up port forwarding on your router if you want remote access"

exit 0
