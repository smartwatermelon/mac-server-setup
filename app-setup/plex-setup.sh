#!/usr/bin/env bash
#
# plex-setup.sh - Plex Media Server setup script for Mac Mini M2 server
#
# This script sets up Plex Media Server in a Docker container with:
# - SMB mount to NAS for media storage (retrieved from config.conf)
# - Configuration migration from existing Plex server
# - Auto-start configuration for operator user
#
# Usage: ./plex-setup.sh [--force] [--skip-migration] [--skip-mount] [--server-name NAME] [--migrate-from HOST]
#   --force: Skip all confirmation prompts
#   --skip-migration: Skip Plex config migration
#   --skip-mount: Skip SMB mount setup
#   --server-name: Set Plex server name (default: hostname)
#   --migrate-from: Source hostname for Plex migration (e.g., old-server.local)
#   Note: --skip-migration and --migrate-from are mutually exclusive
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
CONFIG_FILE="${SCRIPT_DIR}/config.conf"
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

# Parse command line arguments (must come before setting defaults)
FORCE=false
SKIP_MIGRATION=false
SKIP_MOUNT=false
PLEX_SERVER_NAME=""
PLEX_MIGRATE_FROM=""

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
    --migrate-from)
      PLEX_MIGRATE_FROM="$2"
      shift 2
      ;;
    *)
      # Unknown option
      shift
      ;;
  esac
done

# Validate mutually exclusive options
if [[ "${SKIP_MIGRATION}" = true ]] && [[ -n "${PLEX_MIGRATE_FROM}" ]]; then
  echo "Error: --skip-migration and --migrate-from are mutually exclusive"
  exit 1
fi

# Command line --migrate-from takes precedence over config file
# If not specified via command line, use config file value
PLEX_MIGRATE_FROM_CMDLINE="${PLEX_MIGRATE_FROM}"
if [[ -z "${PLEX_MIGRATE_FROM_CMDLINE}" ]]; then
  PLEX_MIGRATE_FROM="${PLEX_MIGRATE_FROM:-}"
else
  PLEX_MIGRATE_FROM="${PLEX_MIGRATE_FROM_CMDLINE}"
fi

# Set default Plex server name to hostname if not specified via command line
if [[ -z "${PLEX_SERVER_NAME}" ]]; then
  PLEX_SERVER_NAME="${HOSTNAME}"
fi

# Plex-specific configuration
PLEX_CONFIG_DIR="${HOME}/Docker/plex/config"
PLEX_MEDIA_MOUNT="/Volumes/${NAS_SHARE_NAME}"
PLEX_MIGRATION_DIR="${HOME}/plex-migration"
PLEX_OLD_CONFIG="${PLEX_MIGRATION_DIR}/Plex Media Server"
PLEX_OLD_PLIST="${PLEX_MIGRATION_DIR}/com.plexapp.plexmediaserver.plist"
PLEX_CONTAINER_NAME="${HOSTNAME_LOWER}-plex"
PLEX_TIMEZONE="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
NAS_SMB_URL="smb://${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME}"

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
      read -p "Continue anyway? (y/N) " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Function to prompt for confirmation with default
# Usage: confirm "message" [default]
#   default: "y" for Yes default (Y/n), "n" for No default (y/N)
#   if no default specified, uses "y" for Yes default
confirm() {
  if [[ "${FORCE}" = false ]]; then
    local message="$1"
    local default="${2:-y}" # Default to Yes if not specified
    local prompt

    if [[ "${default}" = "y" ]]; then
      prompt="${message} (Y/n) "
    else
      prompt="${message} (y/N) "
    fi

    read -p "${prompt}" -n 1 -r
    echo

    # If user just pressed Enter (empty response), use default
    if [[ -z "${REPLY}" ]]; then
      [[ "${default}" = "y" ]]
    else
      [[ ${REPLY} =~ ^[Yy]$ ]]
    fi
  else
    return 0
  fi
}

# Function to discover Plex servers on the network
discover_plex_servers() {
  # Use timeout to limit dns-sd search time, capture output first
  local dns_output
  dns_output=$(timeout 3 dns-sd -B _plexmediasvr._tcp 2>/dev/null)

  # Process the captured output
  local servers
  servers=$(echo "${dns_output}" | grep "Add" | awk '{print $NF}' | sort -u)

  if [[ -n "${servers}" ]]; then
    # Only echo the servers to stdout (for capture), don't mix with log messages
    echo "${servers}"
    return 0
  else
    return 1
  fi
}

# Function to test SSH connectivity to a host
test_ssh_connection() {
  local host="$1"
  log "Testing SSH connection to ${host}..."

  if ssh -o ConnectTimeout=5 -o BatchMode=yes "${host}" 'echo "SSH_OK"' >/dev/null 2>&1; then
    log "✅ SSH connection to ${host} successful"
    return 0
  else
    log "❌ SSH connection to ${host} failed"
    return 1
  fi
}

# Function to get migration size estimate
get_migration_size_estimate() {
  local source_host="$1"
  local plex_path="Library/Application Support/Plex Media Server/"

  log "Getting migration size estimate from ${source_host}..."

  # Get total size
  local total_size
  total_size=$(ssh -o ConnectTimeout=10 "${source_host}" "du -sh '${plex_path}' 2>/dev/null | cut -f1" 2>/dev/null)

  # Get file count
  local file_count
  file_count=$(ssh -o ConnectTimeout=10 "${source_host}" "ls -fR '${plex_path}' 2>/dev/null | wc -l" 2>/dev/null)

  # Get directory count
  local dir_count
  dir_count=$(ssh -o ConnectTimeout=10 "${source_host}" "find '${plex_path}' -type d -not -name '.' -not -name '..' 2>/dev/null | wc -l" 2>/dev/null)

  if [[ -n "${total_size}" && -n "${file_count}" && -n "${dir_count}" ]]; then
    log "Migration size estimate:"
    log "  Total size: ${total_size// /}"
    log "  Files: ${file_count// /}"
    log "  Directories: ${dir_count// /}"
    log "⚠️  Large migrations may take 30+ minutes depending on network speed"
    return 0
  else
    log "⚠️  Could not get size estimate from source server"
    return 1
  fi
}

# Function to setup autofs for automatic SMB mounting
setup_autofs_mount() {
  log "Configuring autofs for automatic SMB mounting..."

  # Check if we have credentials
  local mount_url
  if [[ -f "${SCRIPT_DIR}/plex_nas.conf" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/plex_nas.conf"
    local mount_hostname="${PLEX_NAS_HOSTNAME:-${NAS_HOSTNAME}}"
    mount_url="//${PLEX_NAS_USERNAME:-}:${PLEX_NAS_PASSWORD:-}@${mount_hostname}/${NAS_SHARE_NAME}"
  else
    # For autofs, we'll need to prompt for password or use keychain
    log "⚠️  No 1Password credentials available for autofs setup"
    log "You'll need to manually configure autofs or use Keychain Access for credentials"
    mount_url="//${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME}"
  fi

  # Configure autofs
  local auto_master="/etc/auto_master"
  local auto_smb="/etc/auto_smb"
  local autofs_line="/-          auto_smb    -nosuid,noowners"

  # Check if autofs is already configured
  if grep -q "auto_smb" "${auto_master}" 2>/dev/null; then
    log "autofs already configured in ${auto_master}"
  else
    log "Adding autofs configuration to ${auto_master}..."
    echo "${autofs_line}" | sudo -p "Enter your '${USER}' password to configure autofs: " tee -a "${auto_master}" >/dev/null
    log "✅ Added autofs configuration"
  fi

  # Create auto_smb configuration
  log "Creating autofs SMB configuration..."
  local autofs_mount_line="${PLEX_MEDIA_MOUNT}    -fstype=smbfs,soft,noowners,nosuid,rw :${mount_url}"

  # Create or update auto_smb file
  if [[ -f "${auto_smb}" ]]; then
    if ! grep -q "${PLEX_MEDIA_MOUNT}" "${auto_smb}" 2>/dev/null; then
      echo "${autofs_mount_line}" | sudo -p "Enter your '${USER}' password to update autofs SMB config: " tee -a "${auto_smb}" >/dev/null
      log "✅ Added mount configuration to existing ${auto_smb}"
    else
      log "Mount already configured in ${auto_smb}"
    fi
  else
    echo "${autofs_mount_line}" | sudo -p "Enter your '${USER}' password to create autofs SMB config: " tee "${auto_smb}" >/dev/null
    log "✅ Created ${auto_smb} with mount configuration"
  fi

  # Set proper permissions
  sudo -p "Enter your '${USER}' password to set autofs config permissions: " chmod 644 "${auto_smb}"

  # Restart autofs
  log "Restarting autofs service..."
  if sudo -p "Enter your '${USER}' password to restart autofs service: " automount -cv >/dev/null 2>&1; then
    log "✅ autofs restarted successfully"
    log "The NAS will automatically mount when accessed: ${PLEX_MEDIA_MOUNT}"
    log ""
    log "📝 Note: autofs configuration may be reset during macOS system updates"
    log "   After major updates, you may need to re-run this setup"
  else
    log "⚠️  autofs restart may have failed - check logs if mounting issues occur"
  fi

  # Test the automount
  log "Testing autofs mounting..."
  if ls "${PLEX_MEDIA_MOUNT}" >/dev/null 2>&1; then
    log "✅ autofs mount test successful"
  else
    log "⚠️  autofs mount test failed - manual setup may be required"
    log "   Try accessing ${PLEX_MEDIA_MOUNT} manually to trigger autofs"
  fi
}

# Function to perform automated Plex migration
migrate_plex_from_host() {
  local source_host="$1"

  log "Starting Plex migration from ${source_host}"

  # Test SSH connectivity first
  if ! test_ssh_connection "${source_host}"; then
    log "Cannot proceed with migration - SSH connection failed"
    return 1
  fi

  # Get size estimate
  get_migration_size_estimate "${source_host}"

  # Create migration directory
  log "Creating migration directory: ${PLEX_MIGRATION_DIR}"
  mkdir -p "${PLEX_MIGRATION_DIR}"

  # Define source paths
  local plex_config_source="${source_host}:Library/Application\ Support/Plex\ Media\ Server/"
  local plex_plist_source="${source_host}:Library/Preferences/com.plexapp.plexmediaserver.plist"

  log "Migrating Plex configuration from ${source_host}..."
  log "This may take several minutes depending on the size of your Plex database"

  # Use rsync with progress for the main config
  if command -v rsync >/dev/null 2>&1; then
    # Use rsync with progress but limit output noise
    log "Starting rsync migration (excluding Cache directory)..."
    log "This may take several minutes - progress will be shown periodically"

    # Run rsync and capture output to a temp file for processing
    local rsync_log="/tmp/plex_rsync_$$.log"
    if rsync -aH --progress --compress --whole-file --exclude='Cache' \
      "${plex_config_source}" "${PLEX_MIGRATION_DIR}/" 2>&1 \
      | tee "${rsync_log}" \
      | grep --line-buffered -E "(receiving|sent|total size|\s+[0-9]+%)" \
      | while IFS= read -r line; do
        # Only log percentage updates and summary lines to reduce noise
        if [[ "${line}" =~ [0-9]+% ]] || [[ "${line}" =~ (receiving|sent|total) ]]; then
          log "  ${line// */}" # Remove extra whitespace
        fi
      done; then
      log "✅ Plex configuration migrated successfully"
      rm -f "${rsync_log}"
    else
      log "❌ Plex configuration migration failed"
      if [[ -f "${rsync_log}" ]]; then
        log "Last few lines of rsync output:"
        tail -5 "${rsync_log}" | while IFS= read -r line; do
          log "  ${line}"
        done
        rm -f "${rsync_log}"
      fi
      return 1
    fi
  else
    log "rsync not available, using scp for migration..."
    if scp -r "${source_host}:Library/Application Support/Plex Media Server" "${PLEX_MIGRATION_DIR}/"; then
      log "✅ Plex configuration migrated with scp"
      # Remove Cache directory if it was copied
      if [[ -d "${PLEX_MIGRATION_DIR}/Plex Media Server/Cache" ]]; then
        log "Removing Cache directory from migrated config..."
        rm -rf "${PLEX_MIGRATION_DIR}/Plex Media Server/Cache"
      fi
    else
      log "❌ Plex configuration migration failed with scp"
      return 1
    fi
  fi

  # Copy the plist file
  log "Copying Plex preferences file..."
  if scp "${plex_plist_source}" "${PLEX_MIGRATION_DIR}/" >/dev/null 2>&1; then
    log "✅ Plex preferences file copied to ${PLEX_OLD_PLIST}"
  else
    log "⚠️  Could not copy Plex preferences file (this is optional)"
  fi

  # Verify migration
  if [[ -d "${PLEX_OLD_CONFIG}" ]]; then
    log "✅ Migration completed successfully"
    log "Migrated config available at: ${PLEX_OLD_CONFIG}"
    if [[ -f "${PLEX_OLD_PLIST}" ]]; then
      log "Migrated plist available at: ${PLEX_OLD_PLIST}"
    fi
    return 0
  else
    log "❌ Migration verification failed"
    return 1
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
if confirm "This script will set up Plex Media Server in a Docker container. Continue?" "y"; then
  log "Proceeding with Plex setup"
else
  log "Setup cancelled by user"
  exit 0
fi

# Check Docker configuration and access
section "Checking Docker Access"

# Set up Docker environment to use operator's configuration
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
export DOCKER_CONFIG="${OPERATOR_HOME}/.docker"

if [[ ! -d "${DOCKER_CONFIG}" ]]; then
  log "❌ Docker configuration not found at ${DOCKER_CONFIG}"
  log "Run first-boot.sh to set up Docker/Colima configuration"
  exit 1
fi

# Check if we can access Docker (might need to use operator's context)
if ! docker info &>/dev/null; then
  log "Docker is not running or not accessible"

  # Check if Colima is available and try to start as operator
  if command -v colima &>/dev/null; then
    log "Colima is available but Docker not accessible"
    if confirm "Start Colima as operator?" "y"; then
      log "Starting Colima as operator user..."
      if sudo -p "[Colima setup] Enter password to start Colima as operator: " -u "${OPERATOR_USERNAME}" colima start; then
        log "✅ Colima started successfully"
        # Brief wait for Docker socket to be ready
        sleep 3
        # Verify Docker is now working (test as administrator with operator's config)
        if docker_cmd info &>/dev/null; then
          log "✅ Docker is now accessible"
        else
          log "❌ Docker still not responding after Colima start"
          log "Trying to use Docker through operator context..."
          if sudo -p "[Docker test] Enter password to test Docker access as operator: " -u "${OPERATOR_USERNAME}" docker info &>/dev/null; then
            log "✅ Docker accessible through operator context"
            log "Administrator will use sudo -u ${OPERATOR_USERNAME} for Docker commands"
            USE_OPERATOR_CONTEXT=true
          else
            log "❌ Docker not accessible in any context"
            exit 1
          fi
        fi
      else
        log "❌ Failed to start Colima"
        exit 1
      fi
    else
      log "Please start Colima manually and run the script again:"
      log "  sudo -p '[Colima setup] Enter password to start Colima: ' -u ${OPERATOR_USERNAME} colima start"
      exit 1
    fi
  else
    log "Colima not found. Install with first-boot.sh"
    exit 1
  fi
else
  log "✅ Docker is accessible"
fi

# Helper function to run Docker commands in the appropriate context
docker_cmd() {
  if [[ "${USE_OPERATOR_CONTEXT:-false}" == "true" ]]; then
    sudo -iu "${OPERATOR_USERNAME}" docker "$@"
  else
    docker "$@"
  fi
}

# Configure Colima mounts for Plex requirements
section "Configuring Colima Mounts"
if command -v colima &>/dev/null; then
  COLIMA_CONFIG="${OPERATOR_HOME}/.colima/default/colima.yaml"

  if [[ -f "${COLIMA_CONFIG}" ]]; then
    log "Checking Colima mount configuration..."

    # Check if required mounts are configured
    VOLUMES_MOUNT_CONFIGURED=false
    CONFIG_MOUNT_CONFIGURED=false

    if grep -q "location: /Volumes" "${COLIMA_CONFIG}"; then
      VOLUMES_MOUNT_CONFIGURED=true
      log "✅ /Volumes mount already configured"
    fi

    if grep -q "location: ${PLEX_CONFIG_DIR%/*}" "${COLIMA_CONFIG}" || grep -q "location: ${HOME}/Docker" "${COLIMA_CONFIG}"; then
      CONFIG_MOUNT_CONFIGURED=true
      log "✅ Config directory mount already configured"
    fi

    # If mounts are missing, configure them
    if [[ "${VOLUMES_MOUNT_CONFIGURED}" = false ]] || [[ "${CONFIG_MOUNT_CONFIGURED}" = false ]]; then
      log "Colima mount configuration needs updating..."

      if confirm "Update Colima configuration to add required mounts?" "y"; then
        # Backup current config
        backup_timestamp=$(date +%Y%m%d_%H%M%S)
        cp "${COLIMA_CONFIG}" "${COLIMA_CONFIG}.backup.${backup_timestamp}"
        log "✅ Backed up current Colima configuration"

        # Check if mounts section exists and is empty
        if grep -q "mounts: \[\]" "${COLIMA_CONFIG}"; then
          log "Adding mount configuration to empty mounts section..."
          sed -i '' 's/mounts: \[\]/mounts:\
  - location: \/Volumes\
    writable: true\
  - location: '"${HOME//\//\\\/}"'\/Docker\
    writable: true/' "${COLIMA_CONFIG}"
        elif grep -q "^mounts:" "${COLIMA_CONFIG}"; then
          log "Adding to existing mounts section..."
          # Add missing mounts to existing section
          if [[ "${VOLUMES_MOUNT_CONFIGURED}" = false ]]; then
            sed -i '' '/^mounts:/a\
  - location: /Volumes\
    writable: true' "${COLIMA_CONFIG}"
          fi
          if [[ "${CONFIG_MOUNT_CONFIGURED}" = false ]]; then
            sed -i '' '/^mounts:/a\
  - location: '"${HOME}"'/Docker\
    writable: true' "${COLIMA_CONFIG}"
          fi
        else
          log "❌ Could not find mounts section in Colima config"
          log "Please manually add these mounts to ${COLIMA_CONFIG}:"
          log "  mounts:"
          log "    - location: /Volumes"
          log "      writable: true"
          log "    - location: ${HOME}/Docker"
          log "      writable: true"
          exit 1
        fi

        log "✅ Updated Colima configuration"

        # Restart Colima to apply changes
        log "Restarting Colima to apply mount configuration..."
        if colima stop && colima start; then
          log "✅ Colima restarted successfully"

          # Verify Docker is still working
          if docker_cmd info &>/dev/null; then
            log "✅ Docker is running after Colima restart"
          else
            log "❌ Docker not responding after Colima restart"
            exit 1
          fi
        else
          log "❌ Failed to restart Colima"
          log "Please restart manually: colima stop && colima start"
          exit 1
        fi
      else
        log "⚠️  Continuing without mount configuration - Docker volumes may not work"
      fi
    fi

    # Verify mounts are working
    log "Verifying Colima VM mount accessibility..."

    # Test /Volumes mount
    if colima ssh -- test -d /Volumes 2>/dev/null; then
      log "✅ /Volumes accessible in Colima VM"
    else
      log "❌ /Volumes not accessible in Colima VM"
      log "This will prevent SMB mount access in containers"
    fi

    # Test config directory mount
    if colima ssh -- test -d "${HOME}/Docker" 2>/dev/null; then
      log "✅ ${HOME}/Docker accessible in Colima VM"
    else
      log "⚠️  ${HOME}/Docker not accessible in Colima VM"
      log "Creating directory and testing access..."
      mkdir -p "${HOME}/Docker"
      if colima ssh -- test -d "${HOME}/Docker" 2>/dev/null; then
        log "✅ ${HOME}/Docker now accessible"
      else
        log "❌ ${HOME}/Docker still not accessible"
        log "Docker volume mounts may fail"
      fi
    fi
  else
    log "No Colima configuration found - using defaults"
  fi
else
  log "Colima not found - assuming Docker Desktop or other Docker runtime"
fi

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
      log "This requires administrator privileges - you may be prompted for your user password"
      sudo -p "Enter your '${USER}' password to create mount point: " mkdir -p "${PLEX_MEDIA_MOUNT}"
      check_success "Mount point creation"

      # Take ownership of the mount point
      log "Setting ownership of mount point to current user"
      sudo -p "Enter your '${USER}' password to set mount point ownership: " chown "${WHOAMI}:staff" "${PLEX_MEDIA_MOUNT}"
      check_success "Mount point ownership setup"
    fi

    # Mount the SMB share
    log "Mounting SMB share..."
    if confirm "Mount NAS share now?" "y"; then
      log "Mounting ${NAS_SMB_URL} at ${PLEX_MEDIA_MOUNT}"

      # Check for Plex NAS credentials file from airdrop-prep
      PLEX_NAS_CREDS_FILE="${SCRIPT_DIR}/plex_nas.conf"
      if [[ -f "${PLEX_NAS_CREDS_FILE}" ]]; then
        log "Using Plex NAS credentials from 1Password"
        # shellcheck source=/dev/null
        source "${PLEX_NAS_CREDS_FILE}"

        # Mount using credentials from 1Password
        # Use PLEX_NAS_HOSTNAME from credentials if available, fall back to config NAS_HOSTNAME
        MOUNT_HOSTNAME="${PLEX_NAS_HOSTNAME:-${NAS_HOSTNAME}}"
        # Convert username to lowercase for SMB compatibility
        MOUNT_USERNAME=$(echo "${PLEX_NAS_USERNAME:-}" | tr '[:upper:]' '[:lower:]')
        log "Attempting mount with: //${MOUNT_USERNAME}@${MOUNT_HOSTNAME}/${NAS_SHARE_NAME}"
        log "Using 1Password credentials for user: ${PLEX_NAS_USERNAME:-} (converted to: ${MOUNT_USERNAME})"
        log "Target hostname: ${MOUNT_HOSTNAME}"
        # Use mount_smbfs with URL-encoded password to handle special characters like @
        ENCODED_PASSWORD=$(printf '%s' "${PLEX_NAS_PASSWORD:-}" | sed 's/@/%40/g')
        MOUNT_OUTPUT=$(mount_smbfs -f 0777 -d 0777 "//${MOUNT_USERNAME}:${ENCODED_PASSWORD}@${MOUNT_HOSTNAME}/${NAS_SHARE_NAME}" "${PLEX_MEDIA_MOUNT}" 2>&1) || true
        MOUNT_EXIT_CODE=$?
        if [[ ${MOUNT_EXIT_CODE} -eq 0 ]]; then
          log "✅ NAS mounted successfully using 1Password credentials"
        else
          log "❌ NAS mount failed with 1Password credentials (exit code: ${MOUNT_EXIT_CODE})"
          if [[ -n "${MOUNT_OUTPUT}" ]]; then
            log "Mount error output:"
            echo "${MOUNT_OUTPUT}" | while IFS= read -r line; do
              log "  ${line}"
            done
          fi
          log "This could indicate:"
          log "  - Incorrect credentials in 1Password"
          log "  - Network connectivity issue to ${MOUNT_HOSTNAME}"
          log "  - SMB authentication format problem"
          log "  - Hostname mismatch (1Password: ${MOUNT_HOSTNAME}, config: ${NAS_HOSTNAME})"
          log "Falling back to interactive prompt..."
          log "⚠️  IMPORTANT: If running remotely (SSH/Screen Sharing), go to the desktop"
          log "   The password dialog will appear on the desktop, not in the terminal"
          # Use mount_smbfs with proper permissions flags as non-root user
          FALLBACK_OUTPUT=$(mount_smbfs -f 0777 -d 0777 "//${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME}" "${PLEX_MEDIA_MOUNT}" 2>&1)
          FALLBACK_EXIT_CODE=$?
          if [[ ${FALLBACK_EXIT_CODE} -eq 0 ]]; then
            log "✅ NAS mounted successfully with interactive prompt"
          else
            log "❌ NAS mount failed completely (exit code: ${FALLBACK_EXIT_CODE})"
            if [[ -n "${FALLBACK_OUTPUT}" ]]; then
              log "Fallback mount error output:"
              echo "${FALLBACK_OUTPUT}" | while IFS= read -r line; do
                log "  ${line}"
              done
            fi
          fi
        fi
      else
        log "No Plex NAS credentials file found - using interactive password prompt"
        log "⚠️  IMPORTANT: If running remotely (SSH/Screen Sharing), go to the desktop"
        log "   The password dialog will appear on the desktop, not in the terminal"
        log "You'll be prompted for the NAS password for user '${NAS_USERNAME}'"

        # Use mount_smbfs with proper permissions flags as non-root user
        NO_CREDS_OUTPUT=$(mount_smbfs -f 0777 -d 0777 "//${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME}" "${PLEX_MEDIA_MOUNT}" 2>&1)
        NO_CREDS_EXIT_CODE=$?
        if [[ ${NO_CREDS_EXIT_CODE} -eq 0 ]]; then
          log "✅ NAS mounted successfully"
        else
          log "❌ NAS mount failed (exit code: ${NO_CREDS_EXIT_CODE})"
          if [[ -n "${NO_CREDS_OUTPUT}" ]]; then
            log "Mount error output:"
            echo "${NO_CREDS_OUTPUT}" | while IFS= read -r line; do
              log "  ${line}"
            done
          fi
        fi
      fi

      # Check if mount failed and provide troubleshooting
      if ! mount | grep -q "${PLEX_MEDIA_MOUNT}"; then
        log "Please verify:"
        log "  - NAS hostname is reachable: ${NAS_HOSTNAME}"
        log "  - Share exists: ${NAS_SHARE_NAME}"
        log "  - Username is correct: ${NAS_USERNAME}"
        log "  - Password is correct"
        log "  - You entered the password in the desktop dialog (if running remotely)"
        if ! confirm "Continue without NAS mount? (You can mount manually later)" "n"; then
          exit 1
        fi
      fi

      # Verify mount succeeded and test access
      if mount | grep -q "${PLEX_MEDIA_MOUNT}"; then
        log "✅ NAS successfully mounted at ${PLEX_MEDIA_MOUNT}"
        log "Testing media access..."
        if ls "${PLEX_MEDIA_MOUNT}" >/dev/null 2>&1; then
          log "✅ Media directory is accessible"
          # Show what's in the directory for verification
          ITEM_COUNT=$(find "${PLEX_MEDIA_MOUNT}" -maxdepth 1 -not -path "${PLEX_MEDIA_MOUNT}" 2>/dev/null | wc -l)
          log "Found ${ITEM_COUNT// /} items in media directory"

          # Setup automatic mount on boot using autofs
          log "Setting up automatic mount restoration using autofs..."
          setup_autofs_mount
        else
          log "⚠️  Media directory mounted but not accessible"
          log "Debugging mount access issue..."

          log "Mount point permissions:"
          if stat -f "Permissions: %Mp%Lp, Owner: %Su:%Sg, Size: %z" "${PLEX_MEDIA_MOUNT}" 2>/dev/null; then
            MOUNT_STAT=$(stat -f "Permissions: %Mp%Lp, Owner: %Su:%Sg, Size: %z" "${PLEX_MEDIA_MOUNT}" 2>/dev/null)
            log "  ${MOUNT_STAT}"
          else
            log "  Unable to get mount point permissions"
          fi

          log "Mount information:"
          mount | grep "${PLEX_MEDIA_MOUNT}" | while IFS= read -r line; do
            log "  ${line}"
          done

          log "Detailed mount point analysis:"
          if [[ -e "${PLEX_MEDIA_MOUNT}" ]]; then
            if [[ -d "${PLEX_MEDIA_MOUNT}" ]]; then
              log "  ✅ Mount point exists as directory"

              # Check if it's actually mounted
              if mount | grep -q "${PLEX_MEDIA_MOUNT}"; then
                log "  ✅ Mount point is actively mounted"

                # Try to determine the mount type and status
                MOUNT_INFO=$(mount | grep "${PLEX_MEDIA_MOUNT}")
                log "  Mount details: ${MOUNT_INFO}"

                # Check for common access issues
                log "  Testing directory access methods:"

                # Test with different access patterns
                if [[ -r "${PLEX_MEDIA_MOUNT}" ]]; then
                  log "    ✅ Directory is readable"
                else
                  log "    ❌ Directory is not readable"
                fi

                if [[ -x "${PLEX_MEDIA_MOUNT}" ]]; then
                  log "    ✅ Directory is executable (traversable)"
                else
                  log "    ❌ Directory is not executable (not traversable)"
                fi

                # Test stat command
                if stat "${PLEX_MEDIA_MOUNT}" >/dev/null 2>&1; then
                  log "    ✅ stat command works"
                  STAT_INFO=$(stat -f "Size: %z, Owner: %Su:%Sg, Mode: %Mp%Lp" "${PLEX_MEDIA_MOUNT}" 2>/dev/null)
                  log "    Stat info: ${STAT_INFO}"
                else
                  log "    ❌ stat command fails"
                fi

                # Test find command
                if find "${PLEX_MEDIA_MOUNT}" -maxdepth 1 >/dev/null 2>&1; then
                  log "    ✅ find command works"
                  FIND_COUNT=$(find "${PLEX_MEDIA_MOUNT}" -maxdepth 1 | wc -l)
                  log "    Find shows ${FIND_COUNT// /} items (including directory itself)"
                else
                  log "    ❌ find command fails"
                fi

                # Check for authentication/session issues
                log "  Possible causes:"
                log "    - SMB authentication expired or invalid"
                log "    - Network connectivity issues"
                log "    - Permission denied by SMB server"
                log "    - Mount succeeded but share is empty or access restricted"

              else
                log "  ❌ Mount point exists but is not actively mounted"
              fi
            else
              log "  ❌ Mount point exists but is not a directory"
            fi
          else
            log "  ❌ Mount point does not exist"
          fi

          log "  Current user: ${WHOAMI}"
          log "  User ID/Group: ${IDU}:${IDG}"
          log "  Effective permissions on parent directory:"
          PARENT_DIR=$(dirname "${PLEX_MEDIA_MOUNT}")
          if stat -f "Permissions: %Mp%Lp, Owner: %Su:%Sg" "${PARENT_DIR}" 2>/dev/null; then
            PARENT_STAT=$(stat -f "Permissions: %Mp%Lp, Owner: %Su:%Sg" "${PARENT_DIR}" 2>/dev/null)
            log "    ${PARENT_STAT}"
          else
            log "    Unable to get parent directory permissions"
          fi
        fi
      else
        log "❌ Mount verification failed - mount may not have succeeded"
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
if ! docker_cmd network inspect "${DOCKER_NETWORK}" &>/dev/null; then
  log "Creating Docker network: ${DOCKER_NETWORK}"
  docker_cmd network create "${DOCKER_NETWORK}"
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

  # Check if we already have migrated config
  if [[ -d "${PLEX_OLD_CONFIG}" ]]; then
    log "Found existing Plex configuration at ${PLEX_OLD_CONFIG}"
    if confirm "Use existing migrated Plex configuration?" "y"; then
      log "Using existing migration at ${PLEX_OLD_CONFIG}"
    else
      log "Removing existing migration to start fresh..."
      rm -rf "${PLEX_MIGRATION_DIR}"
      PLEX_MIGRATE_FROM="" # Force re-prompt
    fi
  fi

  # Determine migration source if not already migrated
  if [[ ! -d "${PLEX_OLD_CONFIG}" ]]; then
    # If no migration source specified, ask user
    if [[ -z "${PLEX_MIGRATE_FROM}" ]]; then
      if confirm "Do you want to migrate from an existing Plex server?" "y"; then
        # Try to discover Plex servers
        log "Scanning for Plex servers on the network..."
        discovered_servers=$(discover_plex_servers)

        if [[ -n "${discovered_servers}" ]]; then
          # Log what was found
          log "Found Plex servers:"
          echo "${discovered_servers}" | while IFS= read -r server; do
            log "  - ${server}"
          done

          # Present discovered servers to user
          log "Select a Plex server to migrate from:"
          server_array=()
          index=1
          while IFS= read -r server; do
            # Clean up the server name (remove any extra whitespace)
            clean_server=$(echo "${server}" | tr -d '[:space:]')
            log "  ${index}. ${clean_server}"
            server_array+=("${clean_server}")
            ((index++))
          done <<<"${discovered_servers}"

          log "  ${index}. Other (enter manually)"

          # Get user selection
          read -rp "Enter selection (1-${index}): " selection
          if [[ "${selection}" -ge 1 && "${selection}" -lt "${index}" ]]; then
            PLEX_MIGRATE_FROM="${server_array[$((selection - 1))]}"
            log "Selected: ${PLEX_MIGRATE_FROM}"
          else
            read -rp "Enter hostname of source Plex server: " PLEX_MIGRATE_FROM
          fi
        else
          read -rp "Enter hostname of source Plex server (e.g., old-server.local): " PLEX_MIGRATE_FROM
        fi
      else
        log "Skipping migration - will start with fresh Plex installation"
      fi
    fi

    # Perform migration if source is specified
    if [[ -n "${PLEX_MIGRATE_FROM}" ]]; then
      log "Migrating Plex configuration from ${PLEX_MIGRATE_FROM}"

      if confirm "Proceed with migration from ${PLEX_MIGRATE_FROM}?" "y"; then
        if migrate_plex_from_host "${PLEX_MIGRATE_FROM}"; then
          log "✅ Automated migration completed successfully"
        else
          log "❌ Automated migration failed"
          if confirm "Continue with fresh Plex installation?" "y"; then
            log "Continuing with fresh installation..."
          else
            log "Migration failed and user chose to exit"
            exit 1
          fi
        fi
      else
        log "Migration cancelled by user"
      fi
    fi
  fi

  # Process migrated config if available
  if [[ -d "${PLEX_OLD_CONFIG}" ]]; then
    if confirm "Apply migrated Plex configuration to Docker container?" "y"; then
      log "Stopping any existing Plex container..."
      docker_cmd stop "${PLEX_CONTAINER_NAME}" 2>/dev/null || true
      docker_cmd rm "${PLEX_CONTAINER_NAME}" 2>/dev/null || true

      log "Backing up any existing config..."
      if [[ -d "${PLEX_CONFIG_DIR}" ]]; then
        backup_dir="${PLEX_CONFIG_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Creating backup at ${backup_dir}"
        mv "${PLEX_CONFIG_DIR}" "${backup_dir}"
        mkdir -p "${PLEX_CONFIG_DIR}"
      fi

      log "Applying migrated configuration to Docker setup..."
      # Copy the already-migrated config (Cache already excluded)
      if command -v rsync >/dev/null 2>&1; then
        rsync -av "${PLEX_OLD_CONFIG}/" "${PLEX_CONFIG_DIR}/"
      else
        cp -R "${PLEX_OLD_CONFIG}"/* "${PLEX_CONFIG_DIR}/"
      fi
      check_success "Plex configuration application"

      # Set proper ownership
      log "Setting proper ownership on config files..."
      chown -R "${IDU}:${IDG}" "${PLEX_CONFIG_DIR}"
      check_success "Config ownership setup"

      log "✅ Migrated configuration applied successfully"
      log ""
      log "📝 Post-migration steps required:"
      log "   1. Start the container and access the web interface"
      log "   2. Update library paths to point to /media/ instead of old paths"
      log "   3. Scan libraries to re-associate media files"
      log "   4. Verify all libraries are working correctly"
    else
      log "Skipping application of migrated config - will start fresh"
    fi
  else
    log "No migrated configuration available - will start with fresh Plex installation"
  fi
else
  log "Skipping configuration migration (--skip-migration specified)"
fi

# Setup Plex container
section "Setting Up Plex Container"

# Check if container already exists
if docker_cmd ps -a --format '{{.Names}}' | grep -q "^${PLEX_CONTAINER_NAME}$"; then
  log "Plex container already exists"

  if ! docker_cmd ps --format '{{.Names}}' | grep -q "^${PLEX_CONTAINER_NAME}$"; then
    log "Starting existing Plex container"
    docker_cmd start "${PLEX_CONTAINER_NAME}"
    check_success "Plex container start"
  else
    log "Plex container is already running"
  fi
else
  log "Creating new Plex container"

  # Get Plex claim token if not migrating
  PLEX_CLAIM_TOKEN=""
  if [[ "${SKIP_MIGRATION}" = true ]] && confirm "Get Plex claim token for initial setup?" "n"; then
    echo "Get a claim token from https://www.plex.tv/claim/"
    echo "It expires after 4 minutes, so be ready to use it immediately"
    read -rp "Enter your Plex claim token (or press Enter to skip): " PLEX_CLAIM_TOKEN
  fi

  # Build docker run command
  DOCKER_CMD=(
    "run" "-d"
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
  docker_cmd "${DOCKER_CMD[@]}"
  check_success "Plex container creation"
fi

# Auto-start configuration via Docker restart policy
section "Auto-Start Configuration"

log "Plex auto-start is handled by Docker's restart policy"
log "When Colima starts (via brew services), Docker starts automatically"
log "Containers with --restart=unless-stopped policy start automatically"

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
if docker_cmd ps --format '{{.Names}}' | grep -q "^${PLEX_CONTAINER_NAME}$"; then
  log "✅ Plex container is running"

  log "Access your Plex server at:"
  log "  Local: http://localhost:32400/web"
  log "  Network: http://${HOSTNAME_LOWER}.local:32400/web"

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
    log "  ⚠️  Point libraries to ${PLEX_MEDIA_MOUNT} paths instead of old paths"
  fi

else
  log "❌ Plex container failed to start properly"
  log "Check logs with: docker_cmd logs ${PLEX_CONTAINER_NAME}"
fi

exit 0
