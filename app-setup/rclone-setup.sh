#!/usr/bin/env bash
#
# rclone-setup.sh - Dropbox synchronization setup script for Mac Mini server
#
# This script sets up rclone-based Dropbox synchronization natively on macOS with:
# - rclone configuration transfer from airdrop-prep.sh setup
# - Periodic Dropbox sync to local filesystem
# - Auto-start configuration via LaunchAgent
#
# Usage: ./rclone-setup.sh [--force] [--skip-sync] [--sync-interval MINUTES]
#   --force: Skip all confirmation prompts
#   --skip-sync: Skip initial sync test
#   --sync-interval: Override sync interval (default from config)
#
# Expected configuration files from airdrop-prep.sh:
#   rclone.conf          # rclone configuration with OAuth tokens (copied to app-setup dir by first-boot.sh)
#   dropbox_sync.conf    # Dropbox sync configuration (copied to app-setup dir by first-boot.sh)
#
# Author: Claude
# Version: 1.0
# Created: 2025-08-22

# Exit on error
set -euo pipefail

# Load server configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Derive configuration variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Parse command line arguments
FORCE=false
SKIP_SYNC=false
SYNC_INTERVAL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --skip-sync)
      SKIP_SYNC=true
      shift
      ;;
    --sync-interval)
      SYNC_INTERVAL_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--force] [--skip-sync] [--sync-interval MINUTES]"
      exit 1
      ;;
  esac
done

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
    log "✅ rclone setup completed successfully with no errors or warnings!"
    return
  fi

  log ""
  log "====== RCLONE SETUP SUMMARY ======"
  log "rclone setup completed, but ${error_count} errors and ${warning_count} warnings occurred:"
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

# Load Dropbox configuration
load_dropbox_config() {
  section "Loading Dropbox Configuration"

  local dropbox_config="${SCRIPT_DIR}/config/dropbox_sync.conf"
  if [[ -f "${dropbox_config}" ]]; then
    log "Loading Dropbox sync configuration from ${dropbox_config}"
    # shellcheck source=/dev/null
    source "${dropbox_config}"
  else
    log "❌ Dropbox configuration file not found: ${dropbox_config}"
    log "This file should have been created by airdrop-prep.sh and copied by first-boot.sh"
    exit 1
  fi

  # Validate required variables
  if [[ -z "${DROPBOX_SYNC_FOLDER:-}" ]]; then
    log "❌ DROPBOX_SYNC_FOLDER not found in configuration"
    exit 1
  fi

  if [[ -z "${RCLONE_REMOTE_NAME:-}" ]]; then
    log "❌ RCLONE_REMOTE_NAME not found in configuration"
    exit 1
  fi

  # Set defaults and apply overrides
  DROPBOX_LOCAL_PATH="${DROPBOX_LOCAL_PATH:-${HOME}/.local/sync/dropbox}"
  DROPBOX_SYNC_INTERVAL="${SYNC_INTERVAL_OVERRIDE:-${DROPBOX_SYNC_INTERVAL:-30}}"

  log "✅ Dropbox configuration loaded:"
  log "   Remote folder: ${DROPBOX_SYNC_FOLDER}"
  log "   Local path: ${DROPBOX_LOCAL_PATH}"
  log "   rclone remote: ${RCLONE_REMOTE_NAME}"
  log "   Sync interval: ${DROPBOX_SYNC_INTERVAL} minutes"
}

# Install rclone configuration
install_rclone_config() {
  section "Installing rclone Configuration"

  local source_config="${SCRIPT_DIR}/config/rclone.conf"
  local target_config="${HOME}/.config/rclone/rclone.conf"

  if [[ ! -f "${source_config}" ]]; then
    log "❌ rclone configuration not found: ${source_config}"
    log "This file should have been created by airdrop-prep.sh and copied by first-boot.sh"
    exit 1
  fi

  log "Installing rclone configuration..."

  # Create rclone config directory
  mkdir -p "${HOME}/.config/rclone"

  # Copy configuration with proper permissions
  cp "${source_config}" "${target_config}"
  chmod 600 "${target_config}"
  check_success "rclone configuration installation"

  # Test configuration
  log "Testing rclone configuration..."
  if rclone lsd "${RCLONE_REMOTE_NAME}:" --max-depth 1 >/dev/null 2>&1; then
    log "✅ rclone configuration test successful"
  else
    log "❌ rclone configuration test failed"
    log "Check network connectivity and OAuth token validity"
    exit 1
  fi
}

# Deploy rclone sync script
deploy_rclone_script() {
  section "Deploying rclone Sync Script"

  local template_script="${SCRIPT_DIR}/templates/start-rclone.sh"
  local operator_home="/Users/${OPERATOR_USERNAME}"
  local operator_script="${operator_home}/.local/bin/start-rclone.sh"

  log "Deploying rclone sync script for operator user..."

  # Verify template exists
  if [[ ! -f "${template_script}" ]]; then
    log "❌ rclone script template not found at ${template_script}"
    exit 1
  fi

  # Create operator's script directory and copy template
  sudo -p "[rclone setup] Enter password to create operator script directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${operator_home}/.local/bin"
  sudo -p "[rclone setup] Enter password to copy rclone script: " -u "${OPERATOR_USERNAME}" cp "${template_script}" "${operator_script}"

  # Replace placeholders with actual values
  sudo -p "[rclone setup] Enter password to configure rclone script: " -u "${OPERATOR_USERNAME}" sed -i '' \
    -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
    -e "s|__DROPBOX_SYNC_FOLDER__|${DROPBOX_SYNC_FOLDER}|g" \
    -e "s|__DROPBOX_LOCAL_PATH__|${DROPBOX_LOCAL_PATH}|g" \
    -e "s|__RCLONE_REMOTE_NAME__|${RCLONE_REMOTE_NAME}|g" \
    -e "s|__DROPBOX_SYNC_INTERVAL__|${DROPBOX_SYNC_INTERVAL}|g" \
    "${operator_script}"

  # Set proper permissions
  sudo -p "[rclone setup] Enter password to set rclone script permissions: " -u "${OPERATOR_USERNAME}" chmod 755 "${operator_script}"
  check_success "rclone script deployment"

  log "✅ rclone sync script deployed to operator account"
}

# Deploy rclone configuration to operator account
deploy_operator_rclone_config() {
  section "Deploying rclone Configuration to Operator Account"

  local admin_config="${HOME}/.config/rclone/rclone.conf"
  local operator_home="/Users/${OPERATOR_USERNAME}"
  local operator_config="${operator_home}/.config/rclone/rclone.conf"

  log "Deploying rclone configuration to operator account..."

  # Create operator's rclone config directory
  sudo -p "[rclone setup] Enter password to create operator rclone config directory: " -u "${OPERATOR_USERNAME}" mkdir -p "${operator_home}/.config/rclone"

  # Copy configuration with proper permissions
  sudo -p "[rclone setup] Enter password to copy rclone config to operator: " cp "${admin_config}" "${operator_config}"
  sudo -p "[rclone setup] Enter password to set operator rclone config ownership: " chown "${OPERATOR_USERNAME}:staff" "${operator_config}"
  sudo -p "[rclone setup] Enter password to set operator rclone config permissions: " chmod 600 "${operator_config}"
  check_success "operator rclone configuration deployment"

  log "✅ rclone configuration deployed to operator account"
}

# Configure rclone auto-start
configure_rclone_autostart() {
  section "Configuring rclone Auto-Start"

  local operator_home="/Users/${OPERATOR_USERNAME}"
  local rclone_script="${operator_home}/.local/bin/start-rclone.sh"
  local launch_agents_dir="${operator_home}/Library/LaunchAgents"
  local plist_name="com.${HOSTNAME_LOWER}.dropbox-sync"
  local plist_file="${launch_agents_dir}/${plist_name}.plist"

  log "Creating LaunchAgent for rclone auto-start..."
  sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${launch_agents_dir}"

  cat <<EOF | sudo -iu "${OPERATOR_USERNAME}" tee "${plist_file}" >/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${rclone_script}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardErrorPath</key>
    <string>${operator_home}/.local/state/${plist_name}.log</string>
    <key>StandardOutPath</key>
    <string>${operator_home}/.local/state/${plist_name}.log</string>
</dict>
</plist>
EOF

  check_success "rclone LaunchAgent creation"

  log "✅ rclone configured to start automatically for ${OPERATOR_USERNAME}"
  log "   Sync script: ${rclone_script}"
  log "   LaunchAgent will auto-load when ${OPERATOR_USERNAME} logs in"
  log "   Sync interval: ${DROPBOX_SYNC_INTERVAL} minutes"
}

# Test initial sync
test_initial_sync() {
  section "Testing Initial Dropbox Sync"

  if [[ "${SKIP_SYNC}" == "true" ]]; then
    log "Skipping initial sync test (--skip-sync specified)"
    return 0
  fi

  # Create local directory if it doesn't exist
  if [[ ! -d "${DROPBOX_LOCAL_PATH}" ]]; then
    log "Creating local sync directory: ${DROPBOX_LOCAL_PATH}"
    mkdir -p "${DROPBOX_LOCAL_PATH}"
  fi

  log "Testing initial Dropbox synchronization..."
  log "This will download content to: ${DROPBOX_LOCAL_PATH}"

  if confirm "Perform initial sync test?" "y"; then
    local remote_path="${RCLONE_REMOTE_NAME}:${DROPBOX_SYNC_FOLDER}"

    log "Starting test sync (this may take a few minutes)..."
    if rclone sync "${remote_path}" "${DROPBOX_LOCAL_PATH}" \
      --progress \
      --transfers 2 \
      --checkers 4 \
      --retries 2 \
      --log-level INFO; then

      log "✅ Initial sync test completed successfully"

      # Show sync results
      local file_count
      file_count=$(find "${DROPBOX_LOCAL_PATH}" -type f | wc -l)
      local dir_size
      dir_size=$(du -sh "${DROPBOX_LOCAL_PATH}" 2>/dev/null | cut -f1)

      log "Sync results:"
      log "  Files synced: ${file_count// /}"
      log "  Total size: ${dir_size}"
      log "  Local directory: ${DROPBOX_LOCAL_PATH}"
    else
      log "❌ Initial sync test failed"
      log "Check network connectivity and Dropbox permissions"
      return 1
    fi
  else
    log "Skipping initial sync test"
  fi
}

# Main execution
main() {
  section "rclone Dropbox Sync Setup"
  log "Starting rclone setup for ${HOSTNAME}"

  # Confirm setup
  if ! confirm "Set up rclone Dropbox synchronization?" "y"; then
    log "Setup cancelled by user"
    exit 0
  fi

  # Load Dropbox configuration
  load_dropbox_config

  # Install rclone configuration
  install_rclone_config

  # Deploy to operator account
  deploy_rclone_script
  deploy_operator_rclone_config

  # Configure auto-start
  configure_rclone_autostart

  # Test initial sync
  test_initial_sync

  section "Setup Complete"
  log "✅ rclone Dropbox sync setup completed successfully"
  log "Sync configuration:"
  log "  Remote folder: ${DROPBOX_SYNC_FOLDER}"
  log "  Local directory: ${DROPBOX_LOCAL_PATH}"
  log "  Sync interval: ${DROPBOX_SYNC_INTERVAL} minutes"
  log "  Operator script: /Users/${OPERATOR_USERNAME}/.local/bin/start-rclone.sh"
  log ""
  log "The sync service will start automatically when ${OPERATOR_USERNAME} logs in"
  log "Monitor sync logs at: /Users/${OPERATOR_USERNAME}/.local/state/com.${HOSTNAME_LOWER}.dropbox-sync.log"
  log ""
  log "Manual sync commands:"
  log "  Start sync: sudo -iu ${OPERATOR_USERNAME} /Users/${OPERATOR_USERNAME}/.local/bin/start-rclone.sh"
  log "  Check status: launchctl list | grep dropbox-sync"
  log "  View logs: tail -f /Users/${OPERATOR_USERNAME}/.local/state/com.${HOSTNAME_LOWER}.dropbox-sync.log"
}

# Run main function
main "$@"

# Show collected errors and warnings
show_collected_issues
