#!/usr/bin/env bash
#
# plex-setup.sh - Native Plex Media Server setup script for Mac Mini server
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
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"

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
PLEX_MEDIA_MOUNT="${HOME}/.local/mnt/${NAS_SHARE_NAME}"
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
    collect_error "$1 failed"
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

# Error and warning collection system
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
CURRENT_SCRIPT_SECTION=""

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

# Function to collect an error (with immediate display)
collect_error() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line (replace newlines with spaces)
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  log "❌ ${clean_message}"
  COLLECTED_ERRORS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to collect a warning (with immediate display)
collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line (replace newlines with spaces)
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  log "⚠️ ${clean_message}"
  COLLECTED_WARNINGS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to show collected errors and warnings at end
show_collected_issues() {
  local error_count=${#COLLECTED_ERRORS[@]}
  local warning_count=${#COLLECTED_WARNINGS[@]}

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    log "✅ Plex setup completed successfully with no errors or warnings!"
    return
  fi

  log ""
  log "====== PLEX SETUP SUMMARY ======"
  log "Plex setup completed, but ${error_count} errors and ${warning_count} warnings occurred:"
  log ""

  if [[ ${error_count} -gt 0 ]]; then
    log "ERRORS:"
    for error in "${COLLECTED_ERRORS[@]}"; do
      log "  ${error}"
    done
    log ""
  fi

  if [[ ${warning_count} -gt 0 ]]; then
    log "WARNINGS:"
    for warning in "${COLLECTED_WARNINGS[@]}"; do
      log "  ${warning}"
    done
    log ""
  fi

  log "Review the full log for details: ${LOG_FILE}"
}

# Function to retrieve credentials from Keychain
get_keychain_credential() {
  local service="$1"
  local account="$2"
  local credential

  if credential=$(security find-internet-password -s "${service}" -a "${account}" -w 2>/dev/null); then
    echo "${credential}"
    return 0
  else
    return 1
  fi
}

confirm() {
  if [[ "${FORCE}" == "true" ]]; then
    return 0
  fi

  local prompt="$1"
  local default="${2:-y}"

  if [[ "${default}" == "y" ]]; then
    read -rp "${prompt} (Y/n): " -n 1 response
    echo
    response=${response:-y}
  else
    read -rp "${prompt} (y/N): " -n 1 response
    echo
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

# Per-User SMB Mount Setup (LaunchAgent-based)
setup_persistent_smb_mount() {
  set_section "Setting Up Per-User SMB Mount for Media Storage"

  # Critical safety checks for mount path
  if [[ -z "${NAS_SHARE_NAME}" ]]; then
    collect_error "CRITICAL ERROR: NAS_SHARE_NAME is empty or not set"
    exit 1
  fi

  if [[ "${NAS_SHARE_NAME}" == "." || "${NAS_SHARE_NAME}" == ".." ]]; then
    collect_error "CRITICAL ERROR: NAS_SHARE_NAME cannot be '.' or '..'"
    exit 1
  fi

  log "✅ Mount safety checks passed:"
  log "   NAS_SHARE_NAME: '${NAS_SHARE_NAME}'"
  log "   Admin mount: ${HOME}/.local/mnt/${NAS_SHARE_NAME}"
  log "   Operator mount: /Users/${OPERATOR_USERNAME}/.local/mnt/${NAS_SHARE_NAME}"

  log "Mount scripts will retrieve NAS credentials from Keychain at runtime"

  # Step 1: Configure the template with non-sensitive values
  local template_script="${SCRIPT_DIR}/app-setup-templates/mount-nas-media.sh"
  local configured_script="${SCRIPT_DIR}/mount-nas-media-configured.sh"

  log "Configuring mount script template (credentials retrieved from Keychain at runtime)"

  # Verify template exists
  if [[ ! -f "${template_script}" ]]; then
    log "❌ Mount script template not found at ${template_script}"
    exit 1
  fi

  # Create configured version
  cp "${template_script}" "${configured_script}"

  # Replace placeholders with actual values (no sensitive data)
  sed -i '' \
    -e "s|__NAS_HOSTNAME__|${NAS_HOSTNAME}|g" \
    -e "s|__NAS_SHARE_NAME__|${NAS_SHARE_NAME}|g" \
    -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
    "${configured_script}"

  log "✅ Mount script configured (credentials will be retrieved from Keychain at runtime)"

  # Function to deploy configured script to a specific user
  deploy_user_mount() {
    local target_user="$1"
    local user_home="/Users/${target_user}"

    log "Deploying SMB mount for user: ${target_user}"

    # Create user's script directory and copy configured script
    local user_script_dir="${user_home}/.local/bin"
    local user_script="${user_script_dir}/mount-nas-media.sh"

    sudo -p "[Mount setup] Enter password to create ${target_user} script directory: " -u "${target_user}" mkdir -p "${user_script_dir}"
    sudo -p "[Mount setup] Enter password to copy mount script for ${target_user}: " -u "${target_user}" cp "${configured_script}" "${user_script}"

    # Set proper permissions
    sudo -p "[Mount setup] Enter password to set permissions for ${target_user}'s copy of mount script': " -u "${target_user}" chmod 700 "${user_script}"

    # Create LaunchAgent plist for user
    local user_agents_dir="${user_home}/Library/LaunchAgents"
    local plist_name="com.${HOSTNAME_LOWER}.mount-nas-media"
    local user_plist="${user_agents_dir}/${plist_name}.plist"

    sudo -p "[Mount setup] Enter password to create ${target_user} LaunchAgent directory: " -u "${target_user}" mkdir -p "${user_agents_dir}"

    sudo -p "[Mount setup] Enter password to create ${target_user} LaunchAgent plist: " -u "${target_user}" tee "${user_plist}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${user_script}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>${user_home}/.local/state/${plist_name}.log</string>
    <key>StandardErrorPath</key>
    <string>${user_home}/.local/state/${plist_name}.log</string>
</dict>
</plist>
EOF

    sudo -p "[Mount setup] Enter password to set permissions for ${target_user}'s copy of mount LaunchAgent': " -u "${target_user}" chmod 644 "${user_plist}"
    log "✅ LaunchAgent created for ${target_user}: ${user_plist}"
  }

  # Deploy to both users
  deploy_user_mount "${USER}"
  deploy_user_mount "${OPERATOR_USERNAME}"

  # Clean up temporary configured script
  rm -f "${configured_script}"

  # Test immediate mount for current admin user
  log "Testing immediate SMB mount for admin user..."
  local admin_mount_script="${HOME}/.local/bin/mount-nas-media.sh"
  if [[ -x "${admin_mount_script}" ]]; then
    if "${admin_mount_script}"; then
      log "✅ Admin SMB mount successful"
    else
      log "⚠️  Admin SMB mount failed - check credentials and network connectivity"
    fi
  else
    log "❌ Admin mount script not found or not executable"
  fi

  log ""
  log "✅ Per-User SMB Mount Configuration Complete"
  log "   Admin script: ${HOME}/.local/bin/mount-nas-media.sh"
  log "   Operator script: /Users/${OPERATOR_USERNAME}/.local/bin/mount-nas-media.sh"
  log "   Admin mount: ${HOME}/.local/mnt/${NAS_SHARE_NAME}"
  log "   Operator mount: /Users/${OPERATOR_USERNAME}/.local/mnt/${NAS_SHARE_NAME}"
  log "   LaunchAgents will auto-load when each user logs in"
}

# Install Plex Media Server via Homebrew
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
    log "Plex Media Server is installed via Homebrew"
    log "✅ Using existing Homebrew Plex installation"
    return 0
  fi

  # Verify Homebrew is available
  if ! command -v brew &>/dev/null; then
    log "❌ Homebrew not found - please install Homebrew first"
    exit 1
  fi

  log "Installing Plex Media Server via Homebrew..."
  if brew install --cask plex-media-server; then
    check_success "Plex Media Server installation"
  else
    log "❌ Failed to install Plex Media Server via Homebrew"
    exit 1
  fi

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

  # Deploy Plex startup wrapper script
  OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
  WRAPPER_TEMPLATE="${SCRIPT_DIR}/app-setup-templates/start-plex-with-mount.sh"
  WRAPPER_SCRIPT="${OPERATOR_HOME}/.local/bin/start-plex-with-mount.sh"
  LAUNCH_AGENTS_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
  PLIST_FILE="${LAUNCH_AGENTS_DIR}/com.plexapp.plexmediaserver.plist"

  log "Deploying Plex startup wrapper script..."

  # Verify template exists
  if [[ ! -f "${WRAPPER_TEMPLATE}" ]]; then
    log "❌ Plex wrapper script template not found at ${WRAPPER_TEMPLATE}"
    exit 1
  fi

  # Create operator's script directory and copy template
  sudo -p "[Plex setup] Enter password to create operator script directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_HOME}/.local/bin"
  sudo -p "[Plex setup] Enter password to copy Plex wrapper script: " -u "${OPERATOR_USERNAME}" cp "${WRAPPER_TEMPLATE}" "${WRAPPER_SCRIPT}"

  # Replace placeholders with actual values
  sudo -p "[Plex setup] Enter password to configure Plex wrapper script: " -u "${OPERATOR_USERNAME}" sed -i '' \
    -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
    -e "s|__NAS_SHARE_NAME__|${NAS_SHARE_NAME}|g" \
    "${WRAPPER_SCRIPT}"

  # Set proper permissions
  sudo -p "[Plex setup] Enter password to set Plex wrapper script permissions: " -u "${OPERATOR_USERNAME}" chmod 755 "${WRAPPER_SCRIPT}"
  check_success "Plex wrapper script deployment"

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
        <string>${WRAPPER_SCRIPT}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR</key>
        <string>${PLEX_NEW_CONFIG}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardErrorPath</key>
    <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-plex-launchagent.log</string>
    <key>StandardOutPath</key>
    <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-plex-launchagent.log</string>
</dict>
</plist>
EOF

  check_success "Plex LaunchAgent creation"

  log "✅ Plex configured to start automatically for ${OPERATOR_USERNAME}"
  log "   Wrapper script: ${WRAPPER_SCRIPT}"
  log "   LaunchAgent will auto-load when ${OPERATOR_USERNAME} logs in"
  log "   Plex will wait for SMB mount before starting"
}

# Start Plex Media Server
start_plex() {
  section "Starting Plex Media Server"

  # Set environment variable for current session to use shared config
  export PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR="${PLEX_NEW_CONFIG}"

  # Start Plex as the current user first for initial setup
  log "Starting Plex Media Server for initial configuration..."
  log "Using shared configuration directory: ${PLEX_NEW_CONFIG}"
  log "Note: Plex will request Local Network permission - click Allow when prompted"
  open "/Applications/Plex Media Server.app"

  # Wait a moment for startup
  sleep 5

  # Check if Plex is running
  if pgrep -f "Plex Media Server" >/dev/null; then
    log "✅ Plex Media Server is running"

    # Fix permissions on Plex-created subdirectory
    log "Ensuring proper permissions on Plex configuration directory..."
    if [[ -d "${PLEX_NEW_CONFIG}/Plex Media Server" ]]; then
      sudo -p "Enter your '${USER}' password to fix Plex config permissions: " chown -R "${USER}:staff" "${PLEX_NEW_CONFIG}/Plex Media Server"
      sudo -p "Enter your '${USER}' password to set Plex config permissions: " chmod -R 775 "${PLEX_NEW_CONFIG}/Plex Media Server"
      check_success "Plex configuration permissions fix"
    fi

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
    log "  - Manual mount: mount_smbfs -o soft,nobrowse,noowners '//<username>:<password>@${NAS_HOSTNAME}/${NAS_SHARE_NAME}' '${PLEX_MEDIA_MOUNT}'"
    log "  - Check mounts: mount | grep \$(whoami)"
    log "  - Unmount: umount '${PLEX_MEDIA_MOUNT}'"
    log "  - 'Too many users' error indicates SMB connection limit reached"
    log ""
    log "⚠️  Remember:"
    log "  - Each user has their own private mount in ~/.local/mnt/"
    log "  - Mounts activate when users log in via LaunchAgent"
    log "  - Both admin and operator share same SMB credentials"
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

# Show collected errors and warnings
show_collected_issues
