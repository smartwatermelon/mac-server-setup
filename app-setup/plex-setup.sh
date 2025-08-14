#!/bin/bash
#
# plex-setup.sh - Plex Media Server setup script for Mac Mini M2 server
#
# This script sets up Plex Media Server in a Docker container with:
# - SMB mount to NAS for media storage (retrieved from config.conf)
# - Configuration migration from existing Plex server
# - Auto-start configuration for operator user
#
# Usage: ./plex-setup.sh [--force] [--skip-migration] [--skip-mount] [--server-name NAME]
#   --force: Skip all confirmation prompts
#   --skip-migration: Skip Plex config migration
#   --skip-mount: Skip SMB mount setup
#   --server-name: Set Plex server name (default: hostname)
#
# Expected Plex config files location:
#   ~/plex-migration/
#     ├── Plex Media Server/          # Main config directory from old server
#     └── com.plexapp.plexmediaserver.plist   # macOS preferences file
#
# Author: Claude
# Version: 2.0
# Created: 2025-08-13

# Exit on error
set -euo pipefail

# Load server configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.conf"
IDU="$(id -u)"
IDG="$(id -g)"
WHOAMI="$(whoami)"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
  NAS_USERNAME="${NAS_USERNAME:-plex}"
  NAS_HOSTNAME="${NAS_HOSTNAME:-nas.local}"
  NAS_SHARE_NAME="${NAS_SHARE_NAME:-Media}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Derive configuration variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
DOCKER_NETWORK="${DOCKER_NETWORK_OVERRIDE:-${HOSTNAME_LOWER}-network}"
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-apps.log"

# Set default Plex server name to hostname if not specified
if [[ -z "${PLEX_SERVER_NAME}" ]]; then
  PLEX_SERVER_NAME="${HOSTNAME}"
fi

# Plex-specific configuration
PLEX_CONFIG_DIR="${HOME}/Docker/plex/config"
PLEX_MEDIA_MOUNT="/Volumes/${NAS_SHARE_NAME}"
PLEX_MIGRATION_DIR="${HOME}/plex-migration"
PLEX_OLD_CONFIG="${PLEX_MIGRATION_DIR}/Plex Media Server"
PLEX_CONTAINER_NAME="${HOSTNAME_LOWER}-plex"
PLEX_TIMEZONE="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
NAS_SMB_URL="smb://${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME}"

# Parse command line arguments
FORCE=false
SKIP_MIGRATION=false
SKIP_MOUNT=false
PLEX_SERVER_NAME=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --skip-migration)
      SKIP_MIGRATION=true
      shift
      ;;
    --skip-mount)
      SKIP_MOUNT=true
      shift
      ;;
    --server-name)
      PLEX_SERVER_NAME="$2"
      shift 2
      ;;
    *)
      # Unknown option
      shift
      ;;
  esac
done

# Function to log messages to both console and log file
log() {
  mkdir -p "${LOG_DIR}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] $1"
  echo "[${timestamp}] $1" >>"${LOG_FILE}"
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Function to check if a command was successful
check_success() {
  if [[ $? -eq 0 ]]; then
    log "✅ $1"
  else
    log "❌ $1 failed"
    if [[ "${FORCE}" = false ]]; then
      read -p "Continue anyway? (y/n) " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Function to prompt for confirmation
confirm() {
  if [[ "${FORCE}" = false ]]; then
    read -p "$1 (y/n) " -n 1 -r
    echo
    [[ ${REPLY} =~ ^[Yy]$ ]]
  else
    return 0
  fi
}

# Create log file if it doesn't exist
touch "${LOG_FILE}"

# Print header
section "Setting Up Plex Media Server for ${HOSTNAME}"
log "Running as user: ${WHOAMI}"
log "Server name: ${SERVER_NAME}"
log "Plex server name: ${PLEX_SERVER_NAME}"
log "Operator username: ${OPERATOR_USERNAME}"

# Confirm operation if not forced
# shellcheck disable=2310
if confirm "This script will set up Plex Media Server in a Docker container. Continue?"; then
  log "Proceeding with Plex setup"
else
  log "Setup cancelled by user"
  exit 0
fi

# Check if Docker is running
section "Checking Docker"
if ! docker info &>/dev/null; then
  log "Docker is not running. Please start Docker Desktop first."
  exit 1
fi
log "Docker is running"

# Setup SMB mount to NAS
if [[ "${SKIP_MOUNT}" = false ]]; then
  section "Setting Up NAS Media Mount"

  # Check if mount point already exists and is mounted
  if mount | grep -q "${PLEX_MEDIA_MOUNT}"; then
    log "NAS is already mounted at ${PLEX_MEDIA_MOUNT}"
  else
    log "Setting up SMB mount to NAS: ${NAS_SMB_URL}"

    # Create mount point if it doesn't exist
    if [[ ! -d "${PLEX_MEDIA_MOUNT}" ]]; then
      log "Creating mount point: ${PLEX_MEDIA_MOUNT}"
      sudo mkdir -p "${PLEX_MEDIA_MOUNT}"
      check_success "Mount point creation"
    fi

    # Mount the SMB share
    log "Mounting SMB share..."
    # shellcheck disable=2310
    if confirm "Mount NAS share now? (You may be prompted for NAS credentials)"; then
      # Use osascript to show GUI dialog for credentials if needed
      log "Attempting to mount ${NAS_SMB_URL}"
      open "${NAS_SMB_URL}" 2>/dev/null || {
        log "GUI mount failed, trying command line mount..."
        sudo mount -t smbfs "${NAS_SMB_URL}" "${PLEX_MEDIA_MOUNT}"
      }
      check_success "NAS mount"

      # Verify mount succeeded
      if mount | grep -q "${PLEX_MEDIA_MOUNT}"; then
        log "NAS successfully mounted at ${PLEX_MEDIA_MOUNT}"
        log "Testing media access..."
        if ls "${PLEX_MEDIA_MOUNT}" >/dev/null 2>&1; then
          log "✅ Media directory is accessible"
        else
          log "⚠️  Media directory mounted but not accessible"
        fi
      else
        log "❌ Mount verification failed"
      fi
    else
      log "Skipping NAS mount - you'll need to mount manually later"
    fi
  fi
else
  log "Skipping SMB mount setup (--skip-mount specified)"
fi

# Create Docker network if it doesn't exist
section "Setting Up Docker Network"
if ! docker network inspect "${DOCKER_NETWORK}" &>/dev/null; then
  log "Creating Docker network: ${DOCKER_NETWORK}"
  docker network create "${DOCKER_NETWORK}"
  check_success "Docker network creation"
else
  log "Docker network ${DOCKER_NETWORK} already exists"
fi

# Create Plex configuration directory
section "Setting Up Plex Configuration"
if [[ ! -d "${PLEX_CONFIG_DIR}" ]]; then
  log "Creating Plex config directory: ${PLEX_CONFIG_DIR}"
  mkdir -p "${PLEX_CONFIG_DIR}"
  check_success "Plex config directory creation"
else
  log "Plex config directory already exists"
fi

# Handle Plex configuration migration
if [[ "${SKIP_MIGRATION}" = false ]]; then
  section "Plex Configuration Migration"

  if [[ -d "${PLEX_OLD_CONFIG}" ]]; then
    log "Found existing Plex configuration at ${PLEX_OLD_CONFIG}"

    # shellcheck disable=2310
    if confirm "Migrate existing Plex configuration?"; then
      log "Stopping any existing Plex container..."
      docker stop "${PLEX_CONTAINER_NAME}" 2>/dev/null || true
      docker rm "${PLEX_CONTAINER_NAME}" 2>/dev/null || true

      log "Backing up any existing config..."
      if [[ -d "${PLEX_CONFIG_DIR}" ]]; then
        backup_dir="${PLEX_CONFIG_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Creating backup at ${backup_dir}"
        mv "${PLEX_CONFIG_DIR}" "${backup_dir}"
        mkdir -p "${PLEX_CONFIG_DIR}"
      fi

      log "Copying Plex configuration..."
      cp -R "${PLEX_OLD_CONFIG}"/* "${PLEX_CONFIG_DIR}/"
      check_success "Plex configuration migration"

      # Set proper ownership
      log "Setting proper ownership on config files..."
      chown -R "${IDU}:${IDG}" "${PLEX_CONFIG_DIR}"
      check_success "Config ownership setup"

      log "✅ Plex configuration migrated successfully"
      log "Note: You may need to update library paths after container starts"
    else
      log "Skipping configuration migration"
    fi
  else
    log "No existing Plex configuration found at ${PLEX_OLD_CONFIG}"
    log "Will start with fresh Plex installation"
  fi
else
  log "Skipping configuration migration (--skip-migration specified)"
fi

# Setup Plex container
section "Setting Up Plex Container"

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${PLEX_CONTAINER_NAME}$"; then
  log "Plex container already exists"

  if ! docker ps --format '{{.Names}}' | grep -q "^${PLEX_CONTAINER_NAME}$"; then
    log "Starting existing Plex container"
    docker start "${PLEX_CONTAINER_NAME}"
    check_success "Plex container start"
  else
    log "Plex container is already running"
  fi
else
  log "Creating new Plex container"

  # Get Plex claim token if not migrating
  PLEX_CLAIM_TOKEN=""
  # shellcheck disable=2310
  if [[ "${SKIP_MIGRATION}" = true ]] && confirm "Get Plex claim token for initial setup?"; then
    echo "Get a claim token from https://www.plex.tv/claim/"
    echo "It expires after 4 minutes, so be ready to use it immediately"
    read -rp "Enter your Plex claim token (or press Enter to skip): " PLEX_CLAIM_TOKEN
  fi

  # Build docker run command
  DOCKER_CMD=(
    "docker" "run" "-d"
    "--name=${PLEX_CONTAINER_NAME}"
    "--network=${DOCKER_NETWORK}"
    "--restart=unless-stopped"
    "-e" "TZ=${PLEX_TIMEZONE}"
    "-e" "PUID=${IDU}"
    "-e" "PGID=${IDG}"
    "-e" "HOSTNAME=${PLEX_SERVER_NAME}"
    "-p" "32400:32400/tcp"
    "-p" "3005:3005/tcp"
    "-p" "8324:8324/tcp"
    "-p" "32469:32469/tcp"
    "-p" "1900:1900/udp"
    "-p" "32410:32410/udp"
    "-p" "32412:32412/udp"
    "-p" "32413:32413/udp"
    "-p" "32414:32414/udp"
    "-v" "${PLEX_CONFIG_DIR}:/config"
    "-v" "${PLEX_MEDIA_MOUNT}:/media"
  )

  # Add claim token if provided
  if [[ -n "${PLEX_CLAIM_TOKEN}" ]]; then
    DOCKER_CMD+=("-e" "PLEX_CLAIM=${PLEX_CLAIM_TOKEN}")
  fi

  # Add image
  DOCKER_CMD+=("lscr.io/linuxserver/plex:latest")

  # Run the container
  log "Starting Plex container with LinuxServer.io image..."
  "${DOCKER_CMD[@]}"
  check_success "Plex container creation"
fi

# Setup auto-start for operator user
section "Setting Up Auto-Start for Operator User"

OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
LAUNCHAGENT_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
LAUNCHAGENT_PLIST="${LAUNCHAGENT_DIR}/local.plex.docker.plist"

log "Creating launch agent for automatic Plex startup..."
sudo -u "${OPERATOR_USERNAME}" mkdir -p "${LAUNCHAGENT_DIR}"

# Create launch agent plist
sudo -u "${OPERATOR_USERNAME}" tee "${LAUNCHAGENT_PLIST}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.plex.docker</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/docker</string>
        <string>start</string>
        <string>${PLEX_CONTAINER_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${OPERATOR_HOME}/.local/state/plex-autostart.log</string>
    <key>StandardErrorPath</key>
    <string>${OPERATOR_HOME}/.local/state/plex-autostart.log</string>
</dict>
</plist>
EOF

check_success "Launch agent creation"

# Load the launch agent for the operator user
log "Loading launch agent for operator user..."
sudo -u "${OPERATOR_USERNAME}" launchctl load "${LAUNCHAGENT_PLIST}" 2>/dev/null || {
  log "Launch agent will be loaded when operator user logs in"
}

# Provide final status and instructions
section "Plex Setup Complete"
log "Plex Media Server has been set up successfully"
log "Container name: ${PLEX_CONTAINER_NAME}"
log "Config directory: ${PLEX_CONFIG_DIR}"
log "Media mount: ${PLEX_MEDIA_MOUNT}"

# Wait for Plex to start
log "Waiting for Plex to initialize..."
sleep 10

# Check if Plex is responding
if docker ps --format '{{.Names}}' | grep -q "^${PLEX_CONTAINER_NAME}$"; then
  log "✅ Plex container is running"

  # Get the server's IP address
  SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

  log "Access your Plex server at:"
  log "  Local: http://localhost:32400/web"
  log "  Network: http://${SERVER_IP}:32400/web"

  if [[ -z "${PLEX_CLAIM_TOKEN}" ]] && [[ "${SKIP_MIGRATION}" = true ]]; then
    log ""
    log "⚠️  No claim token provided - you'll need to manually claim the server"
    log "   Visit the web interface and follow the setup wizard"
  fi

  log ""
  log "Auto-start configuration:"
  log "  ✅ Plex will automatically start when ${OPERATOR_USERNAME} logs in"
  log "  ✅ Container restart policy: unless-stopped"

  if [[ "${SKIP_MIGRATION}" = false ]] && [[ -d "${PLEX_OLD_CONFIG}" ]]; then
    log ""
    log "Migration completed:"
    log "  ✅ Configuration migrated from ${PLEX_OLD_CONFIG}"
    log "  ⚠️  You may need to update library paths in the web interface"
    log "  ⚠️  Point libraries to /media/ paths instead of old paths"
  fi

else
  log "❌ Plex container failed to start properly"
  log "Check logs with: docker logs ${PLEX_CONTAINER_NAME}"
fi

exit 0
