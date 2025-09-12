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
# Usage: ./plex-setup.sh [--force] [--migrate] [--skip-migration] [--skip-mount] [--server-name NAME] [--migrate-from HOST] [--custom-port PORT] [--password PASSWORD]
#   --force: Skip all confirmation prompts
#   --clean: Stop and remove existing Plex Media Server if found
#   --migrate: Skip initial migration prompt (for orchestrator use)
#   --skip-migration: Skip Plex config migration
#   --skip-mount: Skip SMB mount setup
#   --server-name: Set Plex server name (default: hostname)
#   --migrate-from: Source hostname for Plex migration (e.g., old-server.local)
#   --custom-port: Set custom port for fresh installations (prevents conflicts)
#   Note: --migrate, --skip-migration, and --migrate-from are mutually exclusive
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
MIGRATE=false
SKIP_MIGRATION=false
SKIP_MOUNT=false
MIGRATE_FROM=""
CUSTOM_PLEX_PORT=""
ADMINISTRATOR_PASSWORD="${ADMINISTRATOR_PASSWORD:-}"
CLEAN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --clean)
      CLEAN=true
      shift
      ;;
    --migrate)
      MIGRATE=true
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
      echo "Usage: $0 [--force] [--clean] [--migrate] [--skip-migration] [--skip-mount] [--server-name NAME] [--migrate-from HOST] [--custom-port PORT] [--password PASSWORD]"
      exit 1
      ;;
  esac
done

# Validate conflicting options
migration_flags=0
[[ "${MIGRATE}" == "true" ]] && ((migration_flags += 1))
[[ "${SKIP_MIGRATION}" == "true" ]] && ((migration_flags += 1))
[[ -n "${MIGRATE_FROM}" ]] && ((migration_flags += 1))

if [[ "${migration_flags}" -gt 1 ]]; then
  echo "Error: --migrate, --skip-migration, and --migrate-from cannot be used together"
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
    # Filter out local hostname to prevent self-migration attempts
    local filtered_servers
    filtered_servers=$(echo "${servers}" | while IFS= read -r server; do
      # Normalize discovered server name: remove .local suffix and convert to uppercase
      local normalized_server="${server%.local}"
      normalized_server="${normalized_server^^}"

      # Compare normalized server name to local hostname
      if [[ "${normalized_server}" != "${HOSTNAME}" ]]; then
        echo "${server}"
      fi
    done)

    if [[ -n "${filtered_servers}" ]]; then
      # Only echo the filtered servers to stdout (for capture), don't mix with log messages
      echo "${filtered_servers}"
      return 0
    else
      # All discovered servers were local - return as if no servers found
      return 1
    fi
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

  # Verify Homebrew is available
  if ! command -v brew &>/dev/null; then
    collect_error "Homebrew not found - please install Homebrew first"
    exit 1
  fi

  if [[ "${CLEAN}" != "true" ]]; then
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
  else # CLEAN = true
    if pgrep -f 'Plex Media Server' &>/dev/null; then
      log "Force stopping all Plex Media Server processes..."
      if sudo -p "Enter password to force-stop all Plex Media Server processes: " pkill -9 -f 'Plex Media Server'; then
        check_success "Force stop all Plex Media Server processes"
      else
        collect_warning "Failed to force stop all Plex Media Server processes"
        if ! confirm "Continue install?" "y"; then
          log "Setup cancelled by user"
          exit 0
        fi
      fi
    fi
    log "Uninstalling Plex Media Server via Homebrew (--clean specified)"
    if brew uninstall --cask --force --zap --ignore-dependencies plex-media-server; then
      check_success "Plex Media Server uninstallation"
    else
      collect_warning "Failed to uninstall Plex Media Server via Homebrew"
      if ! confirm "Continue install?" "y"; then
        log "Setup cancelled by user"
        exit 0
      fi
    fi
  fi

  log "Installing Plex Media Server via Homebrew..."
  if brew install --cask plex-media-server; then
    check_success "Plex Media Server installation"
  else
    collect_error "Failed to install Plex Media Server via Homebrew"
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
    collect_error "Plex application not found at ${plex_app}"
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
  total_size=$(ssh -o ConnectTimeout=10 "${source_host}" "gdu -sh --exclude='localhost' --exclude='Cache' --exclude='PhotoTranscoder' --exclude='Logs' --exclude='Updates' --exclude='*.trace' '${plex_path}' 2>/dev/null | cut -f1" 2>/dev/null)

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

  # Send log messages to stderr to avoid interfering with function return value
  log "Detecting Plex port on source server ${source_host}..." >&2

  # Try to detect port via lsof (most accurate)
  if detected_port=$(ssh -o ConnectTimeout=10 "${source_host}" "lsof -iTCP -sTCP:LISTEN | grep 'Plex Media' | awk '{print \$9}' | cut -d: -f2 | head -1" 2>/dev/null); then
    if [[ -n "${detected_port}" && "${detected_port}" =~ ^[0-9]+$ ]]; then
      log "✅ Detected Plex port via lsof: ${detected_port}" >&2
      echo "${detected_port}"
      return 0
    fi
  fi

  # Fallback: Try common ports
  for port in 32400 32401 32402 32403; do
    log "Testing port ${port} on ${source_host}..." >&2
    if ssh -o ConnectTimeout=5 "${source_host}" "lsof -iTCP:${port} -sTCP:LISTEN" >/dev/null 2>&1; then
      log "✅ Found Plex listening on port: ${port}" >&2
      echo "${port}"
      return 0
    fi
  done

  # Default fallback
  log "⚠️  Could not detect Plex port, assuming default: 32400" >&2
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
    collect_error "Cannot proceed with migration - SSH connection failed"
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

  # Define source paths (properly quoted for spaces)
  # Note: No trailing slash so rsync copies the directory itself, not just contents
  local plex_config_source="${source_host}:Library/Application Support/Plex Media Server"
  local plex_plist_source="${source_host}:Library/Preferences/com.plexapp.plexmediaserver.plist"

  log "Migrating Plex configuration from ${source_host}..."
  log "Excluding large regenerable directories: Cache, PhotoTranscoder, Logs, Updates"
  log "This may take several minutes depending on the size of your Plex database"

  # Use rsync with progress for the main config
  if command -v rsync >/dev/null 2>&1; then
    # Use rsync with progress but limit output noise
    log "Starting rsync migration (excluding Cache directory)..."
    log "Progress will be shown as a single updating line..."

    # Use rsync with clean progress display - no complex background monitoring needed
    local rsync_log="/tmp/plex_rsync_$$.log"
    if rsync -aH --info=progress2 --info=name0 --compress --whole-file \
      --exclude='localhost' \
      --exclude='Cache' \
      --exclude='PhotoTranscoder' \
      --exclude='Logs' \
      --exclude='Updates' \
      --exclude='*.trace' \
      "${plex_config_source}" "${PLEX_OLD_CONFIG%/*}/" 2>&1 | tee "${rsync_log}"; then
      log "✅ Plex configuration migrated successfully"
      rm -f "${rsync_log}"
    else
      collect_error "Plex configuration migration failed"
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
    log "Note: scp cannot exclude directories - full transfer including Cache, PhotoTranscoder, etc."
    if scp -r "${plex_config_source}" "${PLEX_OLD_CONFIG%/*}/"; then
      log "✅ Plex configuration migrated successfully (includes all directories)"
    else
      collect_error "Plex configuration migration failed (scp fallback)"
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

  if [[ ! -d "${PLEX_OLD_CONFIG}" ]]; then
    collect_error "Migration configuration not found at ${PLEX_OLD_CONFIG}"
    log "This indicates migration failed to properly transfer the configuration"
    exit 1
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

    # Update library paths immediately after migration
    update_migrated_library_paths

    # Configure custom port if we have port assignment from migration
    if [[ -n "${TARGET_PLEX_PORT:-}" && "${TARGET_PLEX_PORT}" != "32400" ]]; then
      configure_plex_port "${TARGET_PLEX_PORT}"
    fi
  else
    log "Configuration migration declined by user"
    return 1
  fi
}

# Function to safely update library paths in migrated Plex database
update_migrated_library_paths() {
  log "Updating library paths after migration..."

  # Only update paths if this was a migration
  if [[ -z "${MIGRATE_FROM:-}" ]]; then
    log "   No migration performed - library path updates not needed"
    return 0
  fi

  # Define Plex database paths
  local plex_app_support="${PLEX_NEW_CONFIG}"
  local plex_db_path="${plex_app_support}/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
  local backup_db_path="${plex_app_support}/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db.backup-migration"

  # Verify database exists
  if [[ ! -f "${plex_db_path}" ]]; then
    log "⚠️  Plex database not found at: ${plex_db_path}"
    log "   Library paths may need manual configuration"
    return 0
  fi

  # Use Plex's custom SQLite tool for database operations
  local plex_sqlite="/Applications/Plex Media Server.app/Contents/MacOS/Plex SQLite"

  if [[ ! -f "${plex_sqlite}" ]]; then
    log "❌ Plex SQLite tool not found at: ${plex_sqlite}"
    log "   Library paths may need manual configuration"
    return 1
  fi

  # Check for paths that need updating (any paths containing Media/ in any table)
  log "🔍 Checking for library paths that need updates..."
  local section_paths media_part_paths stream_paths total_paths

  section_paths=$("${plex_sqlite}" "${plex_db_path}" "SELECT COUNT(*) FROM section_locations WHERE instr(root_path, 'Media/') > 0;" 2>/dev/null || echo "0")
  media_part_paths=$("${plex_sqlite}" "${plex_db_path}" "SELECT COUNT(*) FROM media_parts WHERE instr(file, 'Media/') > 0;" 2>/dev/null || echo "0")
  stream_paths=$("${plex_sqlite}" "${plex_db_path}" "SELECT COUNT(*) FROM media_streams WHERE url LIKE 'file:///Users/%' AND instr(url, 'Media/') > 0;" 2>/dev/null || echo "0")

  total_paths=$((section_paths + media_part_paths + stream_paths))

  if [[ "${total_paths}" -eq 0 ]]; then
    log "✅ No library paths need updating"
    return 0
  fi

  log "📊 Found ${total_paths} total paths that need updating:"
  log "   section_locations: ${section_paths} paths"
  log "   media_parts: ${media_part_paths} paths"
  log "   media_streams: ${stream_paths} paths"

  # Create database backup
  log "💾 Creating database backup..."
  if cp "${plex_db_path}" "${backup_db_path}"; then
    log "✅ Database backed up to: ${backup_db_path}"
  else
    log "⚠️  Failed to create database backup - skipping path updates"
    return 1
  fi

  # Show sample paths that will be updated from each table
  log "🔍 Sample paths to be updated:"

  if [[ "${section_paths}" -gt 0 ]]; then
    log "   section_locations (${section_paths} total):"
    "${plex_sqlite}" "${plex_db_path}" "SELECT '    ' || root_path || ' → ${PLEX_MEDIA_MOUNT}/' || substr(root_path, instr(root_path, 'Media/') + length('Media/')) FROM section_locations WHERE instr(root_path, 'Media/') > 0 LIMIT 2;" 2>/dev/null || true
  fi

  if [[ "${media_part_paths}" -gt 0 ]]; then
    log "   media_parts.file (${media_part_paths} total):"
    "${plex_sqlite}" "${plex_db_path}" "SELECT '    ' || substr(file, 1, 60) || '... → ${PLEX_MEDIA_MOUNT}/Media/...' FROM media_parts WHERE instr(file, 'Media/') > 0 LIMIT 2;" 2>/dev/null || true
  fi

  if [[ "${stream_paths}" -gt 0 ]]; then
    log "   media_streams.url (${stream_paths} total):"
    "${plex_sqlite}" "${plex_db_path}" "SELECT '    ' || substr(url, 1, 60) || '... → file://${PLEX_MEDIA_MOUNT}/Media/...' FROM media_streams WHERE url LIKE 'file:///Users/%' AND instr(url, 'Media/') > 0 LIMIT 2;" 2>/dev/null || true
  fi

  # Perform the safe database update across all tables
  log "🔧 Updating library paths in database..."

  # Update section_locations
  local section_result
  section_result=$("${plex_sqlite}" "${plex_db_path}" "UPDATE section_locations SET root_path = '${PLEX_MEDIA_MOUNT}/' || substr(root_path, instr(root_path, 'Media/') + length('Media/')) WHERE instr(root_path, 'Media/') > 0; SELECT changes();" 2>/dev/null || echo "ERROR")

  # Update media_parts.file
  local parts_result
  parts_result=$("${plex_sqlite}" "${plex_db_path}" "UPDATE media_parts SET file = '${PLEX_MEDIA_MOUNT}/' || substr(file, instr(file, 'Media/') + length('Media/')) WHERE instr(file, 'Media/') > 0; SELECT changes();" 2>/dev/null || echo "ERROR")

  # Update media_streams.url (handle file:// URLs)
  local streams_result
  streams_result=$("${plex_sqlite}" "${plex_db_path}" "UPDATE media_streams SET url = 'file://${PLEX_MEDIA_MOUNT}/' || substr(url, instr(url, 'Media/') + length('Media/')) WHERE url LIKE 'file:///Users/%' AND instr(url, 'Media/') > 0; SELECT changes();" 2>/dev/null || echo "ERROR")

  # Check for any errors
  if [[ "${section_result}" == "ERROR" || "${parts_result}" == "ERROR" || "${streams_result}" == "ERROR" ]]; then
    log "❌ Database update failed - restoring backup"
    cp "${backup_db_path}" "${plex_db_path}"
    return 1
  fi

  local total_updated=$((section_result + parts_result + streams_result))

  # Verify the update was successful
  log "✅ Database updated successfully:"
  log "   section_locations: ${section_result} paths changed"
  log "   media_parts: ${parts_result} paths changed"
  log "   media_streams: ${streams_result} paths changed"
  log "   Total: ${total_updated} paths updated"

  # Verify no old path references remain in any table
  log "🔍 Verifying all old path references have been updated..."

  local remaining_section remaining_parts remaining_streams total_remaining
  remaining_section=$("${plex_sqlite}" "${plex_db_path}" "SELECT COUNT(*) FROM section_locations WHERE root_path LIKE '%/Users/%' AND root_path NOT LIKE '/Users/${OPERATOR_USERNAME}/%';" 2>/dev/null || echo "ERROR")
  remaining_parts=$("${plex_sqlite}" "${plex_db_path}" "SELECT COUNT(*) FROM media_parts WHERE file LIKE '%/Users/%' AND file NOT LIKE '/Users/${OPERATOR_USERNAME}/%';" 2>/dev/null || echo "ERROR")
  remaining_streams=$("${plex_sqlite}" "${plex_db_path}" "SELECT COUNT(*) FROM media_streams WHERE url LIKE '%/Users/%' AND url NOT LIKE '%/Users/${OPERATOR_USERNAME}/%';" 2>/dev/null || echo "ERROR")

  total_remaining=$((remaining_section + remaining_parts + remaining_streams))

  if [[ "${total_remaining}" -eq 0 ]]; then
    log "✅ All library paths successfully updated to operator account"
    log "   Sample updated section_locations:"
    "${plex_sqlite}" "${plex_db_path}" "SELECT '    Section ' || library_section_id || ': ' || root_path FROM section_locations LIMIT 2;" 2>/dev/null || true
  else
    log "⚠️  Warning: ${total_remaining} old path references may still exist:"
    log "   section_locations: ${remaining_section}"
    log "   media_parts: ${remaining_parts}"
    log "   media_streams: ${remaining_streams}"
  fi

  # Database integrity check
  log "🔍 Performing database integrity check..."
  local integrity_result
  integrity_result=$("${plex_sqlite}" "${plex_db_path}" "PRAGMA integrity_check;" 2>/dev/null || echo "ERROR")

  if [[ "${integrity_result}" == "ok" ]]; then
    log "✅ Database integrity verified"
  else
    log "❌ Database integrity check failed - restoring backup"
    cp "${backup_db_path}" "${plex_db_path}"
    return 1
  fi

  log "🎉 Library path updates completed successfully"
  log "   Database backup preserved at: ${backup_db_path}"

  return 0
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

# Function to configure Plex port using macOS plist method (for fresh installations)
configure_plex_port_plist() {
  local port="$1"

  log "Configuring Plex to use port ${port} via macOS plist method (operator context)..."

  # Use defaults command in operator context to set the ManualPortMappingPort and enable ManualPortMappingMode
  # This is the official macOS way to configure Plex settings before first startup
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.plexapp.plexmediaserver ManualPortMappingPort -int "${port}"
  sudo -iu "${OPERATOR_USERNAME}" defaults write com.plexapp.plexmediaserver ManualPortMappingMode -int 1

  # Verify the settings were written in operator context
  local configured_port
  configured_port=$(sudo -iu "${OPERATOR_USERNAME}" defaults read com.plexapp.plexmediaserver ManualPortMappingPort 2>/dev/null || echo "")

  if [[ "${configured_port}" == "${port}" ]]; then
    log "✅ Successfully configured Plex for port ${port} using macOS defaults (operator context)"
    log "   Manual port mapping enabled with port ${port}"
    log "   Settings will take effect when Plex starts under ${OPERATOR_USERNAME}"
  else
    collect_error "Failed to configure custom port ${port} in operator's macOS plist"
    return 1
  fi
}

# Configure Plex for auto-start
configure_plex_autostart() {
  section "Configuring Plex Auto-Start"

  # Deploy Plex startup wrapper script
  OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
  WRAPPER_SCRIPT_SOURCE="${SCRIPT_DIR}/templates/start-plex.sh"
  WRAPPER_SCRIPT="${OPERATOR_HOME}/.local/bin/start-plex.sh"
  LAUNCH_AGENTS_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
  PLIST_FILE="${LAUNCH_AGENTS_DIR}/com.plexapp.plexmediaserver.plist"

  log "Deploying Plex startup wrapper script..."

  # Verify source script exists
  if [[ ! -f "${WRAPPER_SCRIPT_SOURCE}" ]]; then
    collect_error "Plex wrapper script not found at ${WRAPPER_SCRIPT_SOURCE}"
    exit 1
  fi

  # Create operator's script directory and copy script (no templating needed)
  sudo -p "[Plex setup] Enter password to create operator script directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_HOME}/.local/bin"
  sudo -p "[Plex setup] Enter password to copy Plex wrapper script: " -u "${OPERATOR_USERNAME}" cp "${WRAPPER_SCRIPT_SOURCE}" "${WRAPPER_SCRIPT}"
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
    collect_warning "Plex Media Server failed to start automatically"
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
    # Skip initial migration prompt if --migrate flag is specified (orchestrator already asked)
    if [[ "${MIGRATE}" == "true" ]] || confirm "Do you want to migrate from an existing Plex server?" "n"; then
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
          # Interactive port selection with validation and retry
          while true; do
            read -rp "Enter port number (1025-65535, e.g., 32401, or 'default' for 32400): " CUSTOM_PLEX_PORT

            # Allow user to type 'default' to use default port
            if [[ "${CUSTOM_PLEX_PORT,,}" == "default" ]]; then
              log "Using default port 32400"
              CUSTOM_PLEX_PORT=""
              break
            fi

            # Validate port number
            if [[ "${CUSTOM_PLEX_PORT}" =~ ^[0-9]+$ && "${CUSTOM_PLEX_PORT}" -gt 1024 && "${CUSTOM_PLEX_PORT}" -lt 65536 ]]; then
              TARGET_PLEX_PORT="${CUSTOM_PLEX_PORT}"
              log "Custom port selected: ${TARGET_PLEX_PORT}"
              break
            else
              echo "❌ Invalid port number. Please enter:"
              echo "   • A port between 1025 and 65535 (e.g., 32401, 32402, 32403)"
              echo "   • Or type 'default' to use port 32400"
            fi
          done
        else
          # Enhanced logging for automation mode when custom port is declined
          if [[ "${FORCE}" == "true" ]]; then
            log "⚠️  Using default port 32400 in automation mode"
            log "⚠️  If port conflicts occur with existing Plex servers:"
            log "   • Rerun with: --custom-port 32401 (or other available port)"
            log "   • Check for other Plex servers: dns-sd -B _plexmediasvr._tcp"
            log "   • Or use run-app-setup.sh --only plex-setup.sh for interactive setup"
          fi
        fi
      else
        # Custom port provided via command line - validate but don't retry interactively
        if [[ "${CUSTOM_PLEX_PORT}" =~ ^[0-9]+$ && "${CUSTOM_PLEX_PORT}" -gt 1024 && "${CUSTOM_PLEX_PORT}" -lt 65536 ]]; then
          TARGET_PLEX_PORT="${CUSTOM_PLEX_PORT}"
          log "Using custom port from command line: ${TARGET_PLEX_PORT}"
        else
          collect_error "Invalid custom port '${CUSTOM_PLEX_PORT}' specified via command line"
          collect_error "Port must be between 1025 and 65535"
          exit 1
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
      # Apply the migrated configuration
      if migrate_plex_config; then
        log "✅ Migrated configuration applied successfully"
      else
        collect_error "Failed to apply migrated configuration after successful remote migration"
        exit 1
      fi
    else
      collect_error "Remote migration from ${MIGRATE_FROM} failed"
      collect_error "Cannot continue with fresh installation when migration was explicitly requested"
      collect_error "Please fix migration issues or run without --migrate-from to do fresh installation"
      exit 1
    fi
  elif [[ "${SKIP_MIGRATION}" != "true" && -d "${PLEX_OLD_CONFIG}" ]]; then
    # Local migration: configuration files are already present
    log "Local migration files found at ${PLEX_OLD_CONFIG}"
    if migrate_plex_config; then
      log "✅ Local migration applied successfully"
    else
      collect_error "Failed to apply local migration configuration"
      exit 1
    fi
  fi

  # Configure custom port for fresh installations (non-migration) using macOS plist method
  if [[ -n "${TARGET_PLEX_PORT:-}" && "${TARGET_PLEX_PORT}" != "32400" && -z "${MIGRATE_FROM}" && ! -d "${PLEX_OLD_CONFIG}" ]]; then
    log "Configuring custom port ${TARGET_PLEX_PORT} for fresh installation using macOS plist method..."
    configure_plex_port_plist "${TARGET_PLEX_PORT}"
  fi

  # Configure auto-start
  configure_plex_autostart

  # Note: Plex will start automatically when operator logs in via LaunchAgent
  log "Plex is configured to start automatically when the operator user logs in"

  section "Setup Complete"
  log "✅ Plex Media Server setup completed successfully"
  log "Configuration directory: ${PLEX_NEW_CONFIG}"
  log "Media directory: ${PLEX_MEDIA_MOUNT}"
  log ""
  log "📋 Next Steps:"
  log "  1. Reboot or log out of the administrator account"
  log "  2. Log in as the '${OPERATOR_USERNAME}' user"
  log "  3. Plex will start automatically on operator login"
  log "  4. Access Plex at: http://${HOSTNAME}.local:32400/web"
  log ""
  log "⚠️  Important: Plex is configured to run under the operator account only"

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
