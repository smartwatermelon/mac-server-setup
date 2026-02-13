#!/usr/bin/env bash
#
# setup-auto-updates.sh - Automated update configuration module
#
# Configures three layers of automated updates for the Mac Mini server:
# 1. Homebrew: Daily formula and cask upgrades via LaunchDaemon (as administrator)
# 2. Mac App Store: Native macOS auto-update (via defaults write)
# 3. macOS Software Update: Weekly download-only via LaunchDaemon (as root)
#
# Homebrew uses a LaunchDaemon (not LaunchAgent) with UserName set to the
# administrator account. LaunchAgents only run when the user has a GUI
# session — the administrator is rarely logged in on the desktop, so a
# LaunchAgent would never fire. LaunchDaemons run regardless of GUI state.
#
# Mac App Store uses macOS's built-in auto-update mechanism rather than
# a mas LaunchAgent, since mas requires a GUI session context.
#
# Usage: ./setup-auto-updates.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-12

set -euo pipefail

# Parse arguments
FORCE=false
for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "Unknown option: ${arg}"
      echo "Usage: $0 [--force]"
      exit 1
      ;;
  esac
done

# Load common configuration
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Error: SERVER_NAME not set in ${CONFIG_FILE}"
  exit 1
fi
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
ADMIN_USER="$(whoami)"

# Logging
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"
mkdir -p "${LOG_DIR}"

log() {
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] $1" | tee -a "${LOG_FILE}"
}

show_log() {
  echo "$1"
  log "$1"
}

section() {
  log ""
  log "====== $1 ======"
}

CURRENT_SCRIPT_SECTION="Setup"

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "${CURRENT_SCRIPT_SECTION}"
}

log_error() {
  local message="$1"
  show_log "ERROR: [${CURRENT_SCRIPT_SECTION}] ${message}"
}

# Confirmation helper
confirm() {
  local prompt="$1"
  local default="${2:-y}"

  if [[ "${FORCE}" == "true" ]]; then
    if [[ "${default}" == "y" ]]; then return 0; else return 1; fi
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
    [yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# Ensure Homebrew environment is available
HOMEBREW_PREFIX="/opt/homebrew"
if [[ -x "${HOMEBREW_PREFIX}/bin/brew" ]]; then
  brew_env=$("${HOMEBREW_PREFIX}/bin/brew" shellenv)
  eval "${brew_env}"
fi

# ============================================================================
# Cleanup: Remove old LaunchAgents from previous deployment
# ============================================================================

cleanup_old_launchagents() {
  local old_brew="${HOME}/Library/LaunchAgents/com.${HOSTNAME_LOWER}.brew-upgrade.plist"
  local old_mas="${HOME}/Library/LaunchAgents/com.${HOSTNAME_LOWER}.mas-upgrade.plist"

  for plist in "${old_brew}" "${old_mas}"; do
    if [[ -f "${plist}" ]]; then
      log "Removing old LaunchAgent: ${plist}"
      launchctl unload "${plist}" 2>/dev/null || true
      rm -f "${plist}"
    fi
  done
}

# ============================================================================
# 5a: Homebrew Auto-Update (daily, as administrator via LaunchDaemon)
# ============================================================================

setup_homebrew_autoupdate() {
  set_section "Homebrew Auto-Update"

  if ! command -v brew >/dev/null 2>&1; then
    log_error "Homebrew not found in PATH"
    return 1
  fi

  local plist_path="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.brew-upgrade.plist"
  local upgrade_script="/usr/local/bin/${HOSTNAME_LOWER}-brew-upgrade.sh"

  # Check if already configured (--force re-applies)
  if sudo test -f "${plist_path}" && sudo test -f "${upgrade_script}" && [[ "${FORCE}" != "true" ]]; then
    log "Homebrew auto-update already configured"
    sudo launchctl load "${plist_path}" 2>/dev/null || true
    return 0
  fi

  # Create upgrade wrapper script (needs Homebrew environment on Apple Silicon)
  log "Creating brew upgrade script at ${upgrade_script}..."

  sudo -p "[Auto-Updates] Enter password to create brew upgrade script: " \
    tee "${upgrade_script}" >/dev/null <<'BREW_EOF'
#!/usr/bin/env bash
# Automated Homebrew upgrade (daily via LaunchDaemon)
set -euo pipefail

# Homebrew environment (Apple Silicon)
eval "$(/opt/homebrew/bin/brew shellenv)"

# Prevent sudo from hanging in unattended context.
# Some cask upgrades invoke sudo for .pkg installers. Without a TTY,
# sudo blocks forever waiting for a password. SUDO_ASKPASS=/bin/false
# makes sudo fail immediately instead of hanging.
export SUDO_ASKPASS=/bin/false
export HOMEBREW_NO_AUTO_UPDATE=1

LOG_FILE="__LOG_DIR__/__HOSTNAME_LOWER__-brew-upgrade.log"
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [brew-upgrade] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

log "Starting daily brew upgrade..."

# Update formulae list
log "Running brew update..."
brew update 2>&1 | tee -a "${LOG_FILE}" || true

# Upgrade formulae first (never need sudo)
log "Running brew upgrade --formula..."
brew upgrade --formula 2>&1 | tee -a "${LOG_FILE}" || true

# Upgrade casks separately — some may fail if they need sudo
log "Running brew upgrade --cask..."
brew upgrade --cask 2>&1 | tee -a "${LOG_FILE}" || true

# Clean up old versions
log "Running brew cleanup..."
brew cleanup --prune=7 2>&1 | tee -a "${LOG_FILE}" || true

log "Brew upgrade complete"
BREW_EOF

  # Replace __PLACEHOLDER__ tokens written by the quoted heredoc above
  sudo sed -i '' "s|__LOG_DIR__|${LOG_DIR}|g" "${upgrade_script}"
  sudo sed -i '' "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" "${upgrade_script}"
  sudo chmod 755 "${upgrade_script}"
  sudo chown root:wheel "${upgrade_script}"

  # Create LaunchDaemon — runs daily at 04:30 as administrator
  log "Creating brew upgrade LaunchDaemon at ${plist_path}..."

  sudo tee "${plist_path}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.brew-upgrade</string>
  <key>UserName</key>
  <string>${ADMIN_USER}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${upgrade_script}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>4</integer>
    <key>Minute</key>
    <integer>30</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/${HOSTNAME_LOWER}-brew-upgrade-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/${HOSTNAME_LOWER}-brew-upgrade-stderr.log</string>
</dict>
</plist>
EOF

  sudo chown root:wheel "${plist_path}"
  sudo chmod 644 "${plist_path}"

  if ! sudo plutil -lint "${plist_path}" >/dev/null 2>&1; then
    log_error "Invalid plist syntax in ${plist_path}"
    return 1
  fi

  # Load the LaunchDaemon
  sudo launchctl load "${plist_path}" 2>/dev/null || true
  show_log "Homebrew auto-update configured and loaded (daily at 04:30, as ${ADMIN_USER})"
}

# ============================================================================
# 5b: Mac App Store Updates (native macOS auto-update)
# ============================================================================

setup_mas_updates() {
  set_section "Mac App Store Auto-Update"

  # Enable macOS built-in App Store auto-updates.
  # This is more reliable than a mas LaunchAgent/Daemon because:
  # - mas requires a GUI session context for App Store authentication
  # - macOS handles this natively without any scheduled task
  log "Enabling macOS built-in App Store auto-updates..."

  if sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool true; then
    show_log "App Store auto-updates enabled (macOS built-in)"
  else
    log_error "Failed to enable App Store auto-updates"
    return 1
  fi

  # Verify
  local auto_update
  auto_update=$(defaults read /Library/Preferences/com.apple.commerce AutoUpdate 2>/dev/null || echo "unset")
  log "com.apple.commerce AutoUpdate = ${auto_update}"
}

# ============================================================================
# 5c: macOS Software Update (weekly, download-only, as root)
# ============================================================================

setup_softwareupdate() {
  set_section "macOS Software Update (Download-Only)"

  local plist_path="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.softwareupdate.plist"

  log "Creating softwareupdate LaunchDaemon at ${plist_path}..."

  # Create a wrapper script that downloads and notifies
  local update_script="/usr/local/bin/${HOSTNAME_LOWER}-softwareupdate.sh"

  sudo -p "[Auto-Updates] Enter password to create softwareupdate script: " \
    tee "${update_script}" >/dev/null <<'UPDATE_EOF'
#!/usr/bin/env bash
# Automated macOS software update downloader (download-only, no install)
set -euo pipefail

LOG_FILE="/var/log/__HOSTNAME_LOWER__-softwareupdate.log"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [softwareupdate] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

log "Starting weekly software update check..."

# Download all available updates (do NOT install)
output=$(softwareupdate --download --all 2>&1) || true
log "softwareupdate output: ${output}"

# Check if updates were downloaded
if echo "${output}" | grep -q "Downloaded"; then
  log "Updates downloaded — manual installation required"

  # Notify administrator via terminal-notifier (if available and running as user)
  # Since this is a LaunchDaemon (root), notification may not appear on GUI.
  # The log file serves as the notification mechanism.
  log "Check System Settings > General > Software Update to install"
fi

log "Software update check complete"
UPDATE_EOF

  # Replace placeholder with actual hostname (uses __VAR__ convention)
  sudo sed -i '' "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" "${update_script}"
  sudo chmod 755 "${update_script}"
  sudo chown root:wheel "${update_script}"

  # Create LaunchDaemon — runs Sundays at 04:00
  sudo tee "${plist_path}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.softwareupdate</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${update_script}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>0</integer>
    <key>Hour</key>
    <integer>4</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>/var/log/${HOSTNAME_LOWER}-softwareupdate-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/${HOSTNAME_LOWER}-softwareupdate-stderr.log</string>
</dict>
</plist>
EOF

  sudo chown root:wheel "${plist_path}"
  sudo chmod 644 "${plist_path}"

  if ! sudo plutil -lint "${plist_path}" >/dev/null 2>&1; then
    log_error "Invalid plist syntax in ${plist_path}"
    return 1
  fi

  # Load the LaunchDaemon (requires sudo)
  sudo launchctl load "${plist_path}" 2>/dev/null || true
  show_log "softwareupdate LaunchDaemon created and loaded (Sundays at 04:00, download-only)"
}

# ============================================================================
# Main
# ============================================================================

main() {
  section "Automated Updates Setup (Stage 5)"
  log "Server: ${HOSTNAME}"
  log "Administrator: ${ADMIN_USER}"

  echo ""
  echo "This script will configure:"
  echo "  1. Homebrew auto-update (daily at 04:30 via LaunchDaemon, as ${ADMIN_USER})"
  echo "  2. Mac App Store auto-update (macOS built-in)"
  echo "  3. macOS Software Update (weekly download-only, Sundays at 04:00)"
  echo ""
  echo "macOS Software Update downloads only — it will NOT auto-install or reboot."
  echo ""

  if ! confirm "Proceed with auto-update setup?" "y"; then
    log "Setup cancelled by user"
    exit 0
  fi

  cleanup_old_launchagents
  setup_homebrew_autoupdate
  setup_mas_updates
  setup_softwareupdate

  section "Auto-Update Setup Complete"
  show_log ""
  show_log "Automated updates configured:"
  show_log "  Homebrew: Daily at 04:30 (LaunchDaemon, as ${ADMIN_USER})"
  show_log "  Mac App Store: macOS built-in auto-update"
  show_log "  macOS: Weekly download-only (Sundays at 04:00)"
  show_log ""
  show_log "Verification:"
  show_log "  sudo launchctl list | grep brew-upgrade"
  show_log "  defaults read /Library/Preferences/com.apple.commerce AutoUpdate"
  show_log "  sudo launchctl list | grep softwareupdate"
  show_log ""
}

main "$@"
exit 0
