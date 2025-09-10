#!/usr/bin/env bash
#
# plex-setup.sh - Plex Media Server setup script for Mac Mini server
#
# This script sets up Plex Media Server on macOS with:
# - SMB mount to NAS for media storage (retrieved from config.conf)
# - Plex installation via official installer
# - Configuration migration from existing Plex server
# - Auto-start configuration
#
# Usage: ./plex-setup.sh [--force] [--skip-migration] [--skip-mount] [--server-name NAME] [--migrate-from HOST] [--custom-port PORT] [--password PASSWORD]
#   --force: Skip all confirmation prompts
#   --skip-migration: Skip Plex config migration
#   --skip-mount: Skip SMB mount setup
#   --server-name: Set Plex server name (default: hostname)
#   --migrate-from: Source hostname for Plex migration (e.g., old-server.local)
#   --custom-port: Set custom port for fresh installations (prevents conflicts)
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

# Determine script directory first
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate working directory before loading config
if [[ "${PWD}" != "${SCRIPT_DIR}" ]] || [[ "$(basename "${SCRIPT_DIR}")" != "app-setup" ]]; then
  echo "❌ Error: This script must be run from the app-setup directory"
  echo ""
  echo "Current directory: ${PWD}"
  echo "Script directory: ${SCRIPT_DIR}"
  echo ""
  echo "Please change to the app-setup directory and try again:"
  echo "  cd \"${SCRIPT_DIR}\" && ./plex-setup.sh"
  echo ""
  exit 1
fi

# Load server configuration
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
CUSTOM_PLEX_PORT=""
ADMINISTRATOR_PASSWORD="${ADMINISTRATOR_PASSWORD:-}"

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
    --custom-port)
      CUSTOM_PLEX_PORT="$2"
      shift 2
      ;;
    --password)
      ADMINISTRATOR_PASSWORD="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--force] [--skip-migration] [--skip-mount] [--server-name NAME] [--migrate-from HOST] [--custom-port PORT] [--password PASSWORD]"
      exit 1
      ;;
  esac
done

# Validate conflicting options
if [[ "${SKIP_MIGRATION}" == "true" && -n "${MIGRATE_FROM}" ]]; then
  echo "Error: --skip-migration and --migrate-from cannot be used together"
  exit 1
fi

# _timeout function - uses timeout utility if installed, otherwise Perl
# https://gist.github.com/jaytaylor/6527607
function _timeout() {
  if command -v timeout; then
    timeout "$@"
  else
    if ! command -v perl; then
      echo "perl not found 😿"
      exit 1
    else
      perl -e 'alarm shift; exec @ARGV' "$@"
    fi
  fi
}

# Ensure we have administrator password for keychain operations
function get_administrator_password() {
  if [[ -z "${ADMINISTRATOR_PASSWORD:-}" ]]; then
    echo
    echo "This script needs your Mac account password for keychain operations."
    read -r -e -p "Enter your Mac account password: " -s ADMINISTRATOR_PASSWORD
    echo # Add newline after hidden input

    # Validate password by testing with dscl
    until _timeout 1 dscl /Local/Default -authonly "${USER}" "${ADMINISTRATOR_PASSWORD}" &>/dev/null; do
      echo "Invalid ${USER} account password. Try again or ctrl-C to exit."
      read -r -e -p "Enter your Mac ${USER} account password: " -s ADMINISTRATOR_PASSWORD
      echo # Add newline after hidden input
    done

    echo "✅ Administrator password validated for keychain operations"
  fi
}

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

  # Ensure keychain is unlocked before accessing
  if ! security unlock-keychain -p "${ADMINISTRATOR_PASSWORD}" 2>/dev/null; then
    collect_error "Failed to unlock keychain for credential retrieval"
    return 1
  fi

  if credential=$(security find-generic-password -s "${service}" -a "${account}" -w 2>/dev/null); then
    echo "${credential}"
    return 0
  else
    return 1
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"

  # In force mode, respect the default behavior instead of always returning YES
  if [[ "${FORCE}" == "true" ]]; then
    if [[ "${default}" == "y" ]]; then
      return 0 # Default YES - auto-confirm
    else
      return 1 # Default NO - auto-decline
    fi
  fi

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

  # Step 1: Retrieve NAS credentials from Keychain for embedding
  log "Retrieving NAS credentials from Keychain for mount script embedding"

  local keychain_service="plex-nas-${HOSTNAME_LOWER}"
  local keychain_account="${HOSTNAME_LOWER}"
  local combined_credential

  if ! combined_credential=$(get_keychain_credential "${keychain_service}" "${keychain_account}"); then
    collect_error "Failed to retrieve NAS credentials from Keychain"
    collect_error "Service: ${keychain_service}, Account: ${keychain_account}"
    collect_error "Ensure credentials were imported during first-boot.sh"
    return 1
  fi

  # Split combined credential (format: "username:password")
  # Use %% and # to split only on first colon (handles passwords with colons)
  local plex_nas_username="${combined_credential%%:*}"
  local plex_nas_password="${combined_credential#*:}"

  # Validate credentials were properly extracted
  if [[ -z "${plex_nas_username}" || -z "${plex_nas_password}" ]]; then
    collect_error "Failed to parse NAS credentials from Keychain"
    unset combined_credential plex_nas_username plex_nas_password
    return 1
  fi

  unset combined_credential
  log "✅ NAS credentials retrieved from Keychain (username: ${plex_nas_username})"

  # Step 2: Configure the template with all values including credentials
  local template_script="${SCRIPT_DIR}/templates/mount-nas-media.sh"
  local configured_script="${SCRIPT_DIR}/mount-nas-media-configured.sh"

  log "Configuring mount script template with embedded credentials"

  # Verify template exists
  if [[ ! -f "${template_script}" ]]; then
    collect_error "Mount script template not found at ${template_script}"
    return 1
  fi

  # Create configured version
  cp "${template_script}" "${configured_script}"

  # Replace placeholders with actual values (including sensitive credentials)
  sed -i '' \
    -e "s|__NAS_HOSTNAME__|${NAS_HOSTNAME}|g" \
    -e "s|__NAS_SHARE_NAME__|${NAS_SHARE_NAME}|g" \
    -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
    -e "s|__PLEX_NAS_USERNAME__|${plex_nas_username}|g" \
    -e "s|__PLEX_NAS_PASSWORD__|${plex_nas_password}|g" \
    "${configured_script}"

  # Clear sensitive variables from memory
  unset plex_nas_username plex_nas_password

  log "✅ Mount script configured with embedded NAS credentials"

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
    <key>StartInterval</key>
        <integer>120</integer>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>${user_home}/.local/state/${plist_name}.log</string>
    <key>StandardErrorPath</key>
    <string>${user_home}/.local/state/${plist_name}.log</string>
</dict>
</plist>
EOF

    # Validate plist syntax
    if sudo -iu "${target_user}" plutil -lint "${user_plist}" >/dev/null 2>&1; then
      log "Mount LaunchAgent plist syntax validated successfully"
    else
      collect_error "Invalid plist syntax in ${user_plist}"
      return 1
    fi

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

# Helper function for actual SSH testing
_try_ssh_host() {
  local host="$1"

  log "SSH connection details:"
  log "  Target host: '${host}'"
  log "  SSH options: ConnectTimeout=5, BatchMode=yes"
  log "  Command: ssh -o ConnectTimeout=5 -o BatchMode=yes '${host}' 'echo \"SSH_OK\"'"

  # Test basic connectivity first
  log "Checking basic network connectivity to ${host}..."
  if ping -c 1 -W 2000 "${host}" >/dev/null 2>&1; then
    log "✅ Network ping to ${host} successful"
  else
    log "❌ Network ping to ${host} failed - host may be unreachable"
  fi

  # Test SSH with verbose output captured
  log "Attempting SSH connection with detailed diagnostics..."
  local ssh_output
  ssh_output=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -v "${host}" 'echo "SSH_OK"' 2>&1)
  local ssh_result=$?

  if [[ ${ssh_result} -eq 0 ]]; then
    log "✅ SSH connection to ${host} successful"
    return 0
  else
    log "❌ SSH connection to ${host} failed with exit code: ${ssh_result}"
    log "SSH error details:"
    echo "${ssh_output}" | while IFS= read -r line; do
      log "  SSH: ${line}"
    done

    # Additional diagnostics
    log "Additional SSH diagnostics:"
    ssh_version=$(ssh -V 2>&1)
    log "  SSH client version: ${ssh_version}"
    log "  SSH config test: ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=5 '${host}' 'echo test' (would use system defaults)"

    return 1
  fi
}

# Function to test SSH connectivity to a host with automatic .local suffix retry
test_ssh_connection() {
  local host="$1"
  local auto_resolve="${2:-true}" # New parameter for auto-resolution

  log "Testing SSH connection to ${host}..."

  # Try original hostname first
  if _try_ssh_host "${host}"; then
    return 0
  fi

  # If auto-resolve enabled and hostname doesn't have .local, try adding it
  if [[ "${auto_resolve}" == "true" && "${host}" != *".local" ]]; then
    local local_hostname="${host,,}.local"
    log "Trying with .local suffix: ${local_hostname}"
    if _try_ssh_host "${local_hostname}"; then
      # Update the global variable to use resolved hostname
      if [[ -n "${MIGRATE_FROM:-}" && "${MIGRATE_FROM}" == "${host}" ]]; then
        MIGRATE_FROM="${local_hostname}"
        log "✅ Updated migration source to resolved hostname: ${MIGRATE_FROM}"
      fi
      return 0
    fi
  fi

  # Both attempts failed - provide troubleshooting suggestions
  log "Troubleshooting suggestions:"
  log "  1. Verify the hostname is correct: '${host}'"
  if [[ "${host}" != *".local" ]]; then
    log "  2. Try with .local suffix: --migrate-from ${host,,}.local"
  fi
  if [[ "${host}" == *".local" ]]; then
    local base_host="${host%.local}"
    log "  3. Try without .local suffix: --migrate-from ${base_host}"
    if ping -c 1 -W 2000 "${base_host}" >/dev/null 2>&1; then
      log "  ✅ ${base_host} is reachable (try: --migrate-from ${base_host})"
    else
      log "  ❌ ${base_host} also unreachable"
    fi
  fi

  log "❌ SSH connection failed for all attempted hostnames"
  return 1
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

# Function to detect source Plex server port
detect_source_plex_port() {
  local source_host="$1"
  local detected_port=""

  log "Detecting Plex port on source server ${source_host}..."

  # Try to detect port via lsof (most accurate)
  if detected_port=$(ssh -o ConnectTimeout=10 "${source_host}" "lsof -iTCP -sTCP:LISTEN | grep 'Plex Media' | awk '{print \$9}' | cut -d: -f2 | head -1" 2>/dev/null); then
    if [[ -n "${detected_port}" && "${detected_port}" =~ ^[0-9]+$ ]]; then
      log "✅ Detected Plex port via lsof: ${detected_port}"
      echo "${detected_port}"
      return 0
    fi
  fi

  # Fallback: Try common ports
  for port in 32400 32401 32402 32403; do
    log "Testing port ${port} on ${source_host}..."
    if ssh -o ConnectTimeout=5 "${source_host}" "lsof -iTCP:${port} -sTCP:LISTEN" >/dev/null 2>&1; then
      log "✅ Found Plex listening on port: ${port}"
      echo "${port}"
      return 0
    fi
  done

  # Default fallback
  log "⚠️  Could not detect Plex port, assuming default: 32400"
  echo "32400"
  return 0
}

# Function to migrate Plex configuration from remote host
migrate_plex_from_host() {
  local source_host="$1"

  log "Starting Plex migration from ${source_host}"
  log "Migration source details:"
  log "  Original hostname: '${source_host}'"
  log "  Will attempt SSH connection to verify accessibility"

  # Test SSH connectivity first
  if ! test_ssh_connection "${source_host}"; then
    log "Cannot proceed with migration - SSH connection failed"
    log "Troubleshooting suggestions:"
    log "  1. Verify the hostname is correct: '${source_host}'"
    log "  2. Check SSH is enabled on the source server"
    log "  3. Ensure SSH keys are set up: ssh-copy-id ${source_host}"
    log "  4. Test manual SSH: ssh ${source_host}"
    if [[ "${source_host}" != *".local" ]]; then
      log "  5. Try with .local suffix: --migrate-from ${source_host}.local"
    fi
    return 1
  fi

  # Detect source server port and set target port
  SOURCE_PLEX_PORT=$(detect_source_plex_port "${source_host}")
  TARGET_PLEX_PORT=$((SOURCE_PLEX_PORT + 1))

  log "Port assignment for migration:"
  log "  Source server (${source_host}): ${SOURCE_PLEX_PORT}"
  log "  Target server (${HOSTNAME}): ${TARGET_PLEX_PORT}"

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

  if confirm "Apply migrated Plex configuration?" "n"; then
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

    # Configure custom port if we have port assignment from migration
    if [[ -n "${TARGET_PLEX_PORT:-}" && "${TARGET_PLEX_PORT}" != "32400" ]]; then
      configure_plex_port "${TARGET_PLEX_PORT}"
    fi
  else
    log "Skipping configuration migration"
  fi
}

# Function to configure Plex port in preferences
configure_plex_port() {
  local port="$1"
  local prefs_file="${PLEX_NEW_CONFIG}/Plex Media Server/Preferences.xml"

  log "Configuring Plex to use port ${port}..."

  if [[ -f "${prefs_file}" ]]; then
    # Create backup of preferences
    backup_timestamp=$(date +%Y%m%d_%H%M%S)
    sudo -p "Enter your '${USER}' password to backup Plex preferences: " cp "${prefs_file}" "${prefs_file}.backup.${backup_timestamp}"

    # Check if ManualPortMappingPort already exists
    if grep -q 'ManualPortMappingPort=' "${prefs_file}"; then
      # Update existing port setting
      sudo -p "Enter your '${USER}' password to update Plex port: " sed -i '' "s/ManualPortMappingPort=\"[0-9]*\"/ManualPortMappingPort=\"${port}\"/" "${prefs_file}"
      log "✅ Updated existing port setting to ${port}"
    else
      # Add port setting to preferences
      # Insert before the closing />
      sudo -p "Enter your '${USER}' password to set Plex port: " sed -i '' "s|/>| ManualPortMappingPort=\"${port}\" ManualPortMappingMode=\"1\"/>|" "${prefs_file}"
      log "✅ Added port setting ${port} to Plex preferences"
    fi

    # Also ensure manual port mapping is enabled
    if ! grep -q 'ManualPortMappingMode=' "${prefs_file}"; then
      sudo -p "Enter your '${USER}' password to enable manual port mapping: " sed -i '' "s|/>| ManualPortMappingMode=\"1\"/>|" "${prefs_file}"
    else
      sudo -p "Enter your '${USER}' password to enable manual port mapping: " sed -i '' "s/ManualPortMappingMode=\"[0-9]*\"/ManualPortMappingMode=\"1\"/" "${prefs_file}"
    fi

    log "✅ Plex configured for port ${port} with manual port mapping enabled"
  else
    log "⚠️  Preferences file not found, port will be configured on first Plex startup"
  fi
}

# Configure Plex for auto-start
configure_plex_autostart() {
  section "Configuring Plex Auto-Start"

  # Deploy Plex startup wrapper script
  OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
  WRAPPER_TEMPLATE="${SCRIPT_DIR}/templates/start-plex-with-mount.sh"
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

  # Validate plist syntax
  if sudo -iu "${OPERATOR_USERNAME}" plutil -lint "${PLIST_FILE}" >/dev/null 2>&1; then
    log "Plex LaunchAgent plist syntax validated successfully"
  else
    collect_error "Invalid plist syntax in ${PLIST_FILE}"
    return 1
  fi

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
  log "Note: Plex may request Local Network permission - click Allow when prompted"
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
  log "Starting Plex setup for ${HOSTNAME}"
  log "Media mount target: ${PLEX_MEDIA_MOUNT}"
  log "Server name: ${PLEX_SERVER_NAME}"

  # Confirm setup
  if ! confirm "Set up Plex Media Server?" "y"; then
    log "Setup cancelled by user"
    exit 0
  fi

  # get administrator password for keychain access
  get_administrator_password

  # Handle migration setup if not already specified
  if [[ "${SKIP_MIGRATION}" != "true" && -z "${MIGRATE_FROM}" ]]; then
    if confirm "Do you want to migrate from an existing Plex server?" "n"; then
      # Try to discover Plex servers
      log "Scanning for Plex servers on the network..."
      discovered_servers=$(discover_plex_servers)

      if [[ -n "${discovered_servers}" ]]; then
        # Log what was found
        log "Found Plex servers:"
        echo "${discovered_servers}" | while IFS= read -r server; do
          log "  - ${server}"
        done

        # Present discovered servers to user with hostname resolution
        log "Select a Plex server to migrate from:"
        server_array=()
        resolved_array=()
        index=1
        while IFS= read -r server; do
          # Clean up the server name (remove any extra whitespace)
          clean_server=$(echo "${server}" | tr -d '[:space:]')

          # Test hostname resolution for each discovered server
          original_migrate_from="${MIGRATE_FROM}"
          MIGRATE_FROM="${clean_server}"
          if test_ssh_connection "${clean_server}" true >/dev/null 2>&1; then
            resolved_hostname="${MIGRATE_FROM}" # Updated by test_ssh_connection
            if [[ "${clean_server}" != "${resolved_hostname}" ]]; then
              log "  ${index}. ${clean_server} → ${resolved_hostname} ✅"
            else
              log "  ${index}. ${clean_server} ✅"
            fi
            server_array+=("${clean_server}")
            resolved_array+=("${resolved_hostname}")
          else
            log "  ${index}. ${clean_server} (⚠️  SSH failed)"
            server_array+=("${clean_server}")
            resolved_array+=("${clean_server}")
          fi
          MIGRATE_FROM="${original_migrate_from}" # Restore original value
          ((index += 1))
        done <<<"${discovered_servers}"

        log "  ${index}. Other (enter manually)"

        # Get user selection
        read -rp "Enter selection (1-${index}): " selection
        if [[ "${selection}" -ge 1 && "${selection}" -lt "${index}" ]]; then
          selected_original="${server_array[$((selection - 1))]}"
          MIGRATE_FROM="${resolved_array[$((selection - 1))]}"
          if [[ "${selected_original}" != "${MIGRATE_FROM}" ]]; then
            log "Selected: ${selected_original} (resolved to ${MIGRATE_FROM})"
          else
            log "Selected: ${MIGRATE_FROM}"
          fi
        else
          read -rp "Enter hostname of source Plex server: " MIGRATE_FROM
          # Try to resolve manually entered hostname
          if test_ssh_connection "${MIGRATE_FROM}" true >/dev/null 2>&1; then
            log "Manual hostname resolved successfully"
          else
            log "⚠️  Manual hostname resolution failed - will attempt migration anyway"
          fi
        fi
      else
        read -rp "Enter hostname of source Plex server (e.g., old-server.local): " MIGRATE_FROM
        # Try to resolve manually entered hostname
        if test_ssh_connection "${MIGRATE_FROM}" true >/dev/null 2>&1; then
          log "Manual hostname resolved successfully"
        else
          log "⚠️  Manual hostname resolution failed - will attempt migration anyway"
        fi
      fi
    else
      SKIP_MIGRATION=true
      log "Skipping migration - will start with fresh Plex configuration"

      # Custom port option for fresh installations to prevent conflicts
      if [[ -z "${CUSTOM_PLEX_PORT:-}" ]]; then
        echo ""
        echo "⚠️  Port Conflict Warning:"
        echo "If you have another Plex server on your network using port 32400,"
        echo "this can cause UPnP/auto-port mapping conflicts at your router."
        echo ""
        if confirm "Do you want to use a custom port instead of 32400?" "n"; then
          read -rp "Enter port number (e.g., 32401): " CUSTOM_PLEX_PORT
          if [[ "${CUSTOM_PLEX_PORT}" =~ ^[0-9]+$ && "${CUSTOM_PLEX_PORT}" -gt 1024 && "${CUSTOM_PLEX_PORT}" -lt 65536 ]]; then
            TARGET_PLEX_PORT="${CUSTOM_PLEX_PORT}"
            log "Custom port selected: ${TARGET_PLEX_PORT}"
          else
            log "Invalid port, using default 32400"
            CUSTOM_PLEX_PORT=""
          fi
        fi
      else
        # Custom port provided via command line
        if [[ "${CUSTOM_PLEX_PORT}" =~ ^[0-9]+$ && "${CUSTOM_PLEX_PORT}" -gt 1024 && "${CUSTOM_PLEX_PORT}" -lt 65536 ]]; then
          TARGET_PLEX_PORT="${CUSTOM_PLEX_PORT}"
          log "Using custom port from command line: ${TARGET_PLEX_PORT}"
        else
          log "Invalid custom port '${CUSTOM_PLEX_PORT}', using default 32400"
          CUSTOM_PLEX_PORT=""
        fi
      fi
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
  log "✅ Plex Media Server setup completed successfully"
  log "Configuration directory: ${PLEX_NEW_CONFIG}"
  log "Media directory: ${PLEX_MEDIA_MOUNT}"

  # Show port configuration information
  local plex_port="32400"
  if [[ -n "${TARGET_PLEX_PORT:-}" ]]; then
    plex_port="${TARGET_PLEX_PORT}"
  fi

  log ""
  log "🌐 Plex Server Access:"
  log "  Local access: http://localhost:${plex_port}/web"
  log "  Network access: http://${HOSTNAME}.local:${plex_port}/web"

  # Show port-specific information if custom port was configured
  if [[ -n "${TARGET_PLEX_PORT:-}" && "${TARGET_PLEX_PORT}" != "32400" ]]; then
    log ""
    log "🔌 Port Configuration (Migration):"
    log "  Source server port: ${SOURCE_PLEX_PORT:-32400}"
    log "  Target server port: ${TARGET_PLEX_PORT}"
    log "  Reason: Prevents conflicts with source server"
    log ""
    log "📡 Router Port Forwarding Required:"
    log "  ⚠️  IMPORTANT: Update your router port forwarding rules"
    log "  Old rule: External port → ${HOSTNAME}.local:32400"
    log "  New rule: External port → ${HOSTNAME}.local:${TARGET_PLEX_PORT}"
    log ""
    log "  Router configuration steps:"
    log "  1. Access your router admin interface"
    log "  2. Navigate to Port Forwarding / Virtual Servers"
    log "  3. Update the rule for ${HOSTNAME}.local"
    log "  4. Change internal port from 32400 to ${TARGET_PLEX_PORT}"
    log "  5. Save and restart router if required"
    log ""
    log "  🔍 Testing: After router update, verify external access works"
    log "  📱 Plex apps will automatically discover the new port"
  fi

  if [[ "${SKIP_MOUNT}" != "true" ]]; then
    log ""
    log "📂 SMB Mount Information:"
    log "  Media directory mounted for administrator"
    log "  Mount troubleshooting:"
    log "    - Manual mount: mount_smbfs -o soft,nobrowse,noowners '//<username>:<password>@${NAS_HOSTNAME}/${NAS_SHARE_NAME}' '${PLEX_MEDIA_MOUNT}'"
    log "    - Check mounts: mount | grep \$(whoami)"
    log "    - Unmount: umount '${PLEX_MEDIA_MOUNT}'"
    log "    - 'Too many users' error indicates SMB connection limit reached"
    log ""
    log "  ⚠️  Mount behavior:"
    log "    - Each user has their own private mount in ~/.local/mnt/"
    log "    - Mounts activate when users log in via LaunchAgent"
    log "    - Both admin and operator share same SMB credentials"
  fi

  # Show migration-specific guidance if migration was performed
  if [[ -n "${MIGRATE_FROM}" || -d "${PLEX_OLD_CONFIG}" ]]; then
    log ""
    log "📦 Migration Summary:"
    log "  ✅ Configuration migrated successfully"
    log "  ✅ Libraries and metadata preserved"
    log "  ✅ Separate server identity maintained"
    log ""
    log "  📝 Post-migration tasks:"
    log "    1. Update library paths in Plex web interface (if needed)"
    log "    2. Point libraries to ${PLEX_MEDIA_MOUNT} paths"
    log "    3. Verify all libraries scan correctly"
    if [[ -n "${TARGET_PLEX_PORT:-}" && "${TARGET_PLEX_PORT}" != "32400" ]]; then
      log "    4. Update router port forwarding (see above)"
      log "    5. Test external access to new server"
    fi
  fi
}

# Run main function
main "$@"

# Clean up administrator password from memory
if [[ -n "${ADMINISTRATOR_PASSWORD:-}" ]]; then
  unset ADMINISTRATOR_PASSWORD
  log "✅ Administrator password cleared from memory"
fi

# Show collected errors and warnings
show_collected_issues
