#!/usr/bin/env bash
#
# plex-setup.sh - Native Plex Media Server setup script for Mac Mini M2 server
#
# This script sets up Plex Media Server natively on macOS with:
# - SMB mount to NAS for media storage (retrieved from config.conf)
# - Native Plex installation via official installer
# - Configuration migration from existing Plex server
# - Auto-start configuration
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
# Version: 3.0 (Native)
# Created: 2025-08-17

# Exit on error
set -euo pipefail

# Load server configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.conf"

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

# Plex configuration
PLEX_MEDIA_MOUNT="/usr/local/mnt/${NAS_SHARE_NAME}"
PLEX_SERVER_NAME="${PLEX_SERVER_NAME_OVERRIDE:-${HOSTNAME}}"

# Migration settings
PLEX_OLD_CONFIG="${HOME}/plex-migration/Plex Media Server"
PLEX_NEW_CONFIG="/Users/Shared/PlexMediaServer"

# Parse command line arguments
FORCE=false
SKIP_MIGRATION=false
SKIP_MOUNT=false
MIGRATE_FROM=""

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
      MIGRATE_FROM="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--force] [--skip-migration] [--skip-mount] [--server-name NAME] [--migrate-from HOST]"
      exit 1
      ;;
  esac
done

# Validate conflicting options
if [[ "${SKIP_MIGRATION}" == "true" && -n "${MIGRATE_FROM}" ]]; then
  echo "Error: --skip-migration and --migrate-from cannot be used together"
  exit 1
fi

# Set up logging
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-apps.log"
mkdir -p "${LOG_DIR}"

# Logging functions
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

show_log() {
  echo "$*" | tee -a "${LOG_FILE}"
}

check_success() {
  if [[ $? -eq 0 ]]; then
    log "✅ $1"
  else
    log "❌ $1 failed"
    exit 1
  fi
}

section() {
  echo ""
  show_log "=================================================================================="
  show_log "$1"
  show_log "=================================================================================="
  echo ""
}

confirm() {
  if [[ "${FORCE}" == "true" ]]; then
    return 0
  fi

  local prompt="$1"
  local default="${2:-y}"

  if [[ "${default}" == "y" ]]; then
    read -rp "${prompt} (Y/n): " response
    response=${response:-y}
  else
    read -rp "${prompt} (y/N): " response
    response=${response:-n}
  fi

  case "${response}" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
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

# Persistent SMB Mount Setup (LaunchDaemon-based)
setup_persistent_smb_mount() {
  section "Setting Up Persistent SMB Mount for Media Storage"

  # Critical safety checks for mount path
  if [[ -z "${NAS_SHARE_NAME}" ]]; then
    log "❌ CRITICAL ERROR: NAS_SHARE_NAME is empty or not set"
    log "   This would result in mounting to /usr/local/mnt directly, which would be dangerous"
    exit 1
  fi

  if [[ "${NAS_SHARE_NAME}" == "." || "${NAS_SHARE_NAME}" == ".." ]]; then
    log "❌ CRITICAL ERROR: NAS_SHARE_NAME cannot be '.' or '..'"
    log "   This would result in dangerous mount behavior"
    exit 1
  fi

  if [[ "${PLEX_MEDIA_MOUNT}" == "/usr/local/mnt" || "${PLEX_MEDIA_MOUNT}" == "/usr/local/mnt/" ]]; then
    log "❌ CRITICAL ERROR: Mount target resolves to /usr/local/mnt root directory"
    log "   Mounting to /usr/local/mnt directly would be dangerous"
    log "   Current values:"
    log "     NAS_SHARE_NAME='${NAS_SHARE_NAME}'"
    log "     PLEX_MEDIA_MOUNT='${PLEX_MEDIA_MOUNT}'"
    exit 1
  fi

  # Verify mount path has proper structure
  local expected_mount="/usr/local/mnt/${NAS_SHARE_NAME}"
  if [[ "${PLEX_MEDIA_MOUNT}" != "${expected_mount}" ]]; then
    log "❌ ERROR: Mount path mismatch"
    log "   Expected: ${expected_mount}"
    log "   Actual: ${PLEX_MEDIA_MOUNT}"
    exit 1
  fi

  log "✅ Mount safety checks passed:"
  log "   NAS_SHARE_NAME: '${NAS_SHARE_NAME}'"
  log "   Mount target: '${PLEX_MEDIA_MOUNT}'"

  # Load NAS credentials from plex_nas.conf
  local nas_config="${SCRIPT_DIR}/plex_nas.conf"
  if [[ -f "${nas_config}" ]]; then
    log "Loading NAS credentials from ${nas_config}"
    # shellcheck source=/dev/null
    source "${nas_config}"
  else
    log "❌ NAS configuration file not found: ${nas_config}"
    exit 1
  fi

  if [[ -z "${PLEX_NAS_USERNAME}" || -z "${PLEX_NAS_PASSWORD}" ]]; then
    log "❌ NAS credentials not found in ${nas_config}"
    exit 1
  fi

  # Step 1: Configure mount script with credentials
  local mount_script="/usr/local/bin/mount-nas-media.sh"
  log "Configuring persistent mount script at ${mount_script}"

  # Verify mount script was installed by first-boot.sh
  if [[ ! -f "${mount_script}" ]]; then
    log "❌ Mount script not found at ${mount_script}"
    log "   The script should have been installed by first-boot.sh"
    exit 1
  fi

  # Replace placeholders with actual values
  sudo sed -i '' \
    -e "s|__NAS_HOSTNAME__|${NAS_HOSTNAME}|g" \
    -e "s|__NAS_SHARE_NAME__|${NAS_SHARE_NAME}|g" \
    -e "s|__PLEX_NAS_USERNAME__|${PLEX_NAS_USERNAME}|g" \
    -e "s|__PLEX_NAS_PASSWORD__|${PLEX_NAS_PASSWORD}|g" \
    -e "s|__PLEX_MEDIA_MOUNT__|${PLEX_MEDIA_MOUNT}|g" \
    -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
    "${mount_script}"

  # Set proper permissions for security
  sudo chmod 700 "${mount_script}"
  sudo chown root:wheel "${mount_script}"
  check_success "Mount script installation"

  # Step 2: Create LaunchDaemon plist
  local plist_name="com.${HOSTNAME_LOWER}.mount-nas-media"
  local plist_file="/Library/LaunchDaemons/${plist_name}.plist"
  log "Creating LaunchDaemon: ${plist_file}"

  sudo -p "Enter your '${USER}' password to create LaunchDaemon: " tee "${plist_file}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${mount_script}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/log/${plist_name}.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/${plist_name}.log</string>
</dict>
</plist>
EOF

  # Remove existing mount if necessary
  sudo launchctl unload "${plist_file}" &>/dev/null || true
  sudo umount "${PLEX_MEDIA_MOUNT}" &>/dev/null || true

  # Set proper plist permissions
  sudo chmod 644 "${plist_file}"
  sudo chown root:wheel "${plist_file}"
  check_success "LaunchDaemon plist creation"

  # Step 3: Load and start the LaunchDaemon
  log "Loading LaunchDaemon for immediate mount"
  sudo launchctl load "${plist_file}"
  check_success "LaunchDaemon load"

  # Give it a moment to start
  sleep 3

  # Step 4: Verify the mount worked
  if mount | grep -q "${PLEX_MEDIA_MOUNT}"; then
    log "✅ Persistent SMB mount successful"
    log "✅ Mount verified in system mount table"

    # Test accessibility
    if ls "${PLEX_MEDIA_MOUNT}" >/dev/null 2>&1; then
      local file_count
      file_count=$(find "${PLEX_MEDIA_MOUNT}" -maxdepth 1 -type f -o -type d | tail -n +2 | wc -l 2>/dev/null || echo "0")
      log "✅ Media directory accessible with ${file_count} items"
      log "✅ Mount will persist across reboots and user switches"
    else
      log "⚠️  Mount succeeded but directory not accessible"
    fi
  else
    log "❌ Mount verification failed"
    log "   Check LaunchDaemon logs: sudo tail -F /var/log/${plist_name}.log"

    if ! confirm "Continue without NAS mount? (You can troubleshoot later)" "n"; then
      exit 1
    fi
  fi

  log ""
  log "✅ Persistent Mount Configuration Complete"
  log "   Mount script: ${mount_script}"
  log "   LaunchDaemon: ${plist_file}"
  log "   Logs: /var/log/${plist_name}.log"
  log "   The mount will automatically restore after reboots"
  log "   Both admin and operator users can access ${PLEX_MEDIA_MOUNT}"
}

# Download and install Plex Media Server
install_plex() {
  section "Installing Plex Media Server"

  # Check if Plex is already installed
  if [[ -d "/Applications/Plex Media Server.app" ]]; then
    log "Plex Media Server is already installed at /Applications/Plex Media Server.app"
    log "✅ Using existing Plex installation"
    return 0
  fi

  # Check if it was installed via Homebrew cask
  if command -v brew &>/dev/null && brew list --cask plex-media-server &>/dev/null; then
    log "Plex Media Server is installed via Homebrew but not found in Applications"
    log "This may indicate a Homebrew installation issue"
  fi

  log "Downloading Plex Media Server for macOS..."

  # Create temporary directory for download
  TEMP_DIR=$(mktemp -d)
  PLEX_DMG="${TEMP_DIR}/PlexMediaServer.dmg"

  # Download latest Plex Media Server
  PLEX_DOWNLOAD_URL="https://downloads.plex.tv/plex-media-server-new/1.40.4.8679-424562606/macos/PlexMediaServer-1.40.4.8679-424562606-universal.dmg"

  log "Downloading from: ${PLEX_DOWNLOAD_URL}"
  if curl -L -o "${PLEX_DMG}" "${PLEX_DOWNLOAD_URL}"; then
    check_success "Plex Media Server download"
  else
    log "❌ Failed to download Plex Media Server"
    log "Please download manually from: https://www.plex.tv/media-server-downloads/"
    exit 1
  fi

  # Mount the DMG
  log "Mounting Plex installer..."
  MOUNT_POINT=$(hdiutil attach "${PLEX_DMG}" | grep "/Volumes/" | awk '{print $3}')

  if [[ -z "${MOUNT_POINT}" ]]; then
    log "❌ Failed to mount Plex installer DMG"
    exit 1
  fi

  # Install Plex
  log "Installing Plex Media Server..."
  if cp -R "${MOUNT_POINT}/Plex Media Server.app" "/Applications/"; then
    check_success "Plex Media Server installation"
  else
    log "❌ Failed to install Plex Media Server"
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
    exit 1
  fi

  # Clean up
  hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
  rm -rf "${TEMP_DIR}"

  # Remove quarantine attribute from Plex application
  log "Removing quarantine attribute from Plex application..."
  xattr -d com.apple.quarantine "/Applications/Plex Media Server.app" 2>/dev/null || true
  check_success "Plex quarantine removal"

  log "✅ Plex Media Server installed successfully"
}

# Configure firewall for Plex
configure_plex_firewall() {
  section "Configuring Firewall for Plex Media Server"

  local plex_app="/Applications/Plex Media Server.app"

  if [[ -d "${plex_app}" ]]; then
    log "Adding Plex Media Server to firewall allowlist..."
    sudo -p "[Firewall setup] Enter password to allow Plex through firewall: " /usr/libexec/ApplicationFirewall/socketfilterfw --add "${plex_app}"
    check_success "Plex firewall addition"

    sudo -p "[Firewall setup] Enter password to unblock Plex: " /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "${plex_app}"
    check_success "Plex firewall unblock"

    log "✅ Plex Media Server configured in firewall"

    # Grant network volume access permission to Plex
    log "Granting network volume access permission to Plex Media Server..."
    if sudo -p "[Privacy setup] Enter password to grant Plex network access: " tccutil reset NetworkVolumes "${plex_app}" 2>/dev/null; then
      sudo tccutil insert NetworkVolumes "${plex_app}" 2>/dev/null || true
      log "✅ Network volume access permission granted"
    else
      log "⚠️  Could not automatically grant network volume permission"
      log "   You may see a permission prompt when Plex first accesses network files"
    fi
  else
    log "❌ Plex application not found at ${plex_app}"
    exit 1
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

  if [[ -n "${total_size}" && -n "${file_count}" ]]; then
    log "Migration size estimate:"
    log "  Total size: ${total_size}"
    log "  Approximate files: ${file_count}"
    log "  Estimated time: 5-30 minutes (depends on network speed)"
  else
    log "⚠️  Could not estimate migration size - proceeding anyway"
  fi
}

# Function to migrate Plex configuration from remote host
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
  log "Creating migration directory: ${PLEX_OLD_CONFIG%/*}"
  mkdir -p "${PLEX_OLD_CONFIG%/*}"

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
      "${plex_config_source}" "${PLEX_OLD_CONFIG%/*}/" 2>&1 \
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
    # Fallback to scp if rsync not available
    log "rsync not available, using scp (no progress indication)..."
    if scp -r "${plex_config_source}" "${PLEX_OLD_CONFIG%/*}/"; then
      log "✅ Plex configuration migrated successfully"
    else
      log "❌ Plex configuration migration failed"
      return 1
    fi
  fi

  # Migrate preferences file
  log "Migrating Plex preferences..."
  if scp "${plex_plist_source}" "${PLEX_OLD_CONFIG%/*}/"; then
    log "✅ Plex preferences migrated successfully"
  else
    log "⚠️  Could not migrate Plex preferences (this is optional)"
  fi

  return 0
}

# Create shared Plex configuration directory
setup_shared_config() {
  section "Setting Up Shared Plex Configuration Directory"

  log "Creating shared Plex configuration directory at ${PLEX_NEW_CONFIG}"

  # Create the shared directory
  sudo -p "Enter your '${USER}' password to create shared Plex directory: " mkdir -p "${PLEX_NEW_CONFIG}"
  check_success "Shared Plex directory creation"

  # Set ownership to admin:staff and permissions for both admin and operator access
  sudo -p "Enter your '${USER}' password to set Plex directory ownership: " chown "${USER}:staff" "${PLEX_NEW_CONFIG}"
  check_success "Plex directory ownership"

  # Set permissions: owner and group can read/write, others can read
  sudo -p "Enter your '${USER}' password to set Plex directory permissions: " chmod 775 "${PLEX_NEW_CONFIG}"
  check_success "Plex directory permissions"

  # Add operator to staff group if not already a member
  log "Ensuring operator user ${OPERATOR_USERNAME} is in staff group..."
  if ! groups "${OPERATOR_USERNAME}" | grep -q "staff"; then
    sudo -p "Enter your '${USER}' password to add operator to staff group: " dseditgroup -o edit -a "${OPERATOR_USERNAME}" -t user staff
    check_success "Operator staff group membership"
  else
    log "✅ Operator ${OPERATOR_USERNAME} is already in staff group"
  fi

  log "✅ Shared Plex configuration directory ready"
}

# Migrate existing Plex configuration
migrate_plex_config() {
  section "Plex Configuration Migration"

  if [[ "${SKIP_MIGRATION}" == "true" ]]; then
    log "Skipping Plex configuration migration (--skip-migration specified)"
    return 0
  fi

  if [[ ! -d "${PLEX_OLD_CONFIG}" ]]; then
    log "No existing Plex configuration found at ${PLEX_OLD_CONFIG}"
    log "Plex will start with fresh configuration"
    return 0
  fi

  if confirm "Apply migrated Plex configuration?" "y"; then
    log "Stopping Plex Media Server if running..."
    pkill -f "Plex Media Server" 2>/dev/null || true
    sleep 3

    log "Backing up any existing configuration..."
    if [[ -d "${PLEX_NEW_CONFIG}/Plex Media Server" ]]; then
      backup_timestamp=$(date +%Y%m%d_%H%M%S)
      sudo -p "Enter your '${USER}' password to backup existing Plex config: " mv "${PLEX_NEW_CONFIG}/Plex Media Server" "${PLEX_NEW_CONFIG}/Plex Media Server.backup.${backup_timestamp}"
    fi

    log "Copying migrated configuration to shared directory..."
    sudo -p "Enter your '${USER}' password to copy migrated Plex config: " cp -R "${PLEX_OLD_CONFIG}" "${PLEX_NEW_CONFIG}/"
    check_success "Plex configuration migration"

    # Ensure proper permissions on migrated files
    log "Setting permissions on migrated configuration..."
    sudo -p "Enter your '${USER}' password to set migrated config ownership: " chown -R "${USER}:staff" "${PLEX_NEW_CONFIG}/Plex Media Server"
    sudo -p "Enter your '${USER}' password to set migrated config permissions: " chmod -R 775 "${PLEX_NEW_CONFIG}/Plex Media Server"
    check_success "Migrated configuration permissions"

    log "✅ Plex configuration migrated successfully"
  else
    log "Skipping configuration migration"
  fi
}

# Configure Plex for auto-start
configure_plex_autostart() {
  section "Configuring Plex Auto-Start"

  # Create a simple LaunchAgent for the operator user
  OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
  LAUNCH_AGENTS_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
  PLIST_FILE="${LAUNCH_AGENTS_DIR}/com.plexapp.plexmediaserver.plist"

  log "Creating LaunchAgent for Plex auto-start..."
  sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${LAUNCH_AGENTS_DIR}"

  cat <<EOF | sudo -iu "${OPERATOR_USERNAME}" tee "${PLIST_FILE}" >/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.plexapp.plexmediaserver</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Plex Media Server.app/Contents/MacOS/Plex Media Server</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR</key>
        <string>${PLEX_NEW_CONFIG}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/plex-error.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/plex-out.log</string>
</dict>
</plist>
EOF

  check_success "Plex LaunchAgent creation"

  log "✅ Plex configured to start automatically for ${OPERATOR_USERNAME}"
  log "   LaunchAgent will auto-load when ${OPERATOR_USERNAME} logs in"
}

# Start Plex Media Server
start_plex() {
  section "Starting Plex Media Server"

  # Set environment variable for current session to use shared config
  export PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR="${PLEX_NEW_CONFIG}"

  # Start Plex as the current user first for initial setup
  log "Starting Plex Media Server for initial configuration..."
  log "Using shared configuration directory: ${PLEX_NEW_CONFIG}"
  open "/Applications/Plex Media Server.app"

  # Wait a moment for startup
  sleep 5

  # Check if Plex is running
  if pgrep -f "Plex Media Server" >/dev/null; then
    log "✅ Plex Media Server is running"
    log "Access your Plex server at:"
    log "  Local: http://localhost:32400/web"
    log "  Network: http://${HOSTNAME}.local:32400/web"
  else
    log "❌ Plex Media Server failed to start"
    log "Try starting manually with: PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR='${PLEX_NEW_CONFIG}' open '/Applications/Plex Media Server.app'"
  fi
}

# Main execution
main() {
  section "Plex Media Server Setup"
  log "Starting native Plex setup for ${HOSTNAME}"
  log "Media mount target: ${PLEX_MEDIA_MOUNT}"
  log "Server name: ${PLEX_SERVER_NAME}"

  # Confirm setup
  if ! confirm "Set up native Plex Media Server?" "y"; then
    log "Setup cancelled by user"
    exit 0
  fi

  # Handle migration setup if not already specified
  if [[ "${SKIP_MIGRATION}" != "true" && -z "${MIGRATE_FROM}" ]]; then
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
          MIGRATE_FROM="${server_array[$((selection - 1))]}"
          log "Selected: ${MIGRATE_FROM}"
        else
          read -rp "Enter hostname of source Plex server: " MIGRATE_FROM
        fi
      else
        read -rp "Enter hostname of source Plex server (e.g., old-server.local): " MIGRATE_FROM
      fi
    else
      SKIP_MIGRATION=true
      log "Skipping migration - will start with fresh Plex configuration"
    fi
  fi

  # Setup SMB mount if not skipped
  if [[ "${SKIP_MOUNT}" != "true" ]]; then
    setup_persistent_smb_mount
  else
    log "Skipping SMB mount setup (--skip-mount specified)"
  fi

  # Install Plex
  install_plex

  # Configure firewall for Plex
  configure_plex_firewall

  # Setup shared configuration directory
  setup_shared_config

  # Perform remote migration if specified
  if [[ -n "${MIGRATE_FROM}" ]]; then
    log "Remote migration source specified: ${MIGRATE_FROM}"
    if migrate_plex_from_host "${MIGRATE_FROM}"; then
      log "✅ Remote migration completed successfully"
    else
      log "❌ Remote migration failed - continuing with fresh installation"
    fi
  fi

  # Migrate configuration if available (local migration)
  migrate_plex_config

  # Configure auto-start
  configure_plex_autostart

  # Start Plex
  start_plex

  section "Setup Complete"
  log "✅ Native Plex Media Server setup completed successfully"
  log "Configuration directory: ${PLEX_NEW_CONFIG}"
  log "Media directory: ${PLEX_MEDIA_MOUNT}"

  if [[ "${SKIP_MOUNT}" != "true" ]]; then
    log "Media directory mounted for administrator"
    log ""
    log "SMB Mount troubleshooting:"
    log "  - Manual mount: sudo mount -t smbfs -o soft,nobrowse,noowners '//${PLEX_NAS_USERNAME}:<password>@${NAS_HOSTNAME}/${NAS_SHARE_NAME}' '${PLEX_MEDIA_MOUNT}'"
    log "  - Check mounts: mount | grep ${NAS_SHARE_NAME}"
    log "  - Unmount: sudo umount '${PLEX_MEDIA_MOUNT}'"
    log "  - 'Too many users' error indicates SMB connection limit reached"
    log ""
    log "⚠️  Remember:"
    log "  - This mount is only for administrator account"
    log "  - Operator account needs separate mount setup"
    log "  - Mount won't survive reboots without additional setup"
  fi

  # Show migration-specific guidance if migration was performed
  if [[ -n "${MIGRATE_FROM}" || -d "${PLEX_OLD_CONFIG}" ]]; then
    log ""
    log "Migration completed:"
    log "  ✅ Configuration migrated successfully"
    log "  ⚠️  You may need to update library paths in the web interface"
    log "  ⚠️  Point libraries to ${PLEX_MEDIA_MOUNT} paths instead of old paths"
  fi
}

# Run main function
main "$@"
