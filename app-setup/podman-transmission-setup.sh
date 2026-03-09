#!/usr/bin/env bash
#
# podman-transmission-setup.sh - Containerized Transmission (haugene + Podman) setup
#
# Installs Podman, creates a rootful Podman machine named 'transmission-vm', deploys
# the haugene/transmission-openvpn container stack, and creates the LaunchAgents that
# keep everything running at login. Replaces the native Transmission.app + PIA Desktop
# split tunnel stack with a kernel-level VPN-enforced container.
#
# Components deployed:
#   ~/containers/transmission/compose.yml           — haugene container definition
#   ~/containers/transmission/scripts/              — container-side scripts
#   ~/containers/transmission/.env                  — PIA credentials (mode 600)
#   ~/.local/bin/podman-machine-start.sh            — starts machine + compose at login
#   ~/.local/bin/transmission-trigger-watcher.sh    — polls NAS .done/ dir, invokes FileBot
#   ~/Library/LaunchAgents/com.<host>.podman-transmission-vm.plist
#   ~/Library/LaunchAgents/com.<host>.transmission-trigger-watcher.plist
#
# Prerequisites:
#   - Homebrew installed
#   - config/config.conf configured (ONEPASSWORD_PIA_ITEM, PIA_VPN_REGION, LAN_SUBNET)
#   - PIA credentials stored in keychain (run prep-airdrop.sh first)
#   - NAS mounted at ~/.local/mnt/DSMedia
#
# Usage: ./podman-transmission-setup.sh [--force]
#   --force: Skip all confirmation prompts
#
# See docs/plans/2026-03-08-containerized-transmission.md for full implementation plan.
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-03-08

set -euo pipefail

# ---------------------------------------------------------------------------
# Homebrew environment
# ---------------------------------------------------------------------------

HOMEBREW_PREFIX="/opt/homebrew" # Apple Silicon
if [[ -x "${HOMEBREW_PREFIX}/bin/brew" ]]; then
  brew_env=$("${HOMEBREW_PREFIX}/bin/brew" shellenv)
  eval "${brew_env}"
  echo "Homebrew environment configured"
elif command -v brew >/dev/null 2>&1; then
  echo "Homebrew already in PATH"
else
  echo "❌ Homebrew not found — podman-transmission setup requires Homebrew"
  echo "Please ensure first-boot.sh completed successfully before running app setup"
  exit 1
fi

# ---------------------------------------------------------------------------
# Script directory + working directory check
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${PWD}" != "${SCRIPT_DIR}" ]] || [[ "$(basename "${SCRIPT_DIR}")" != "app-setup" ]]; then
  echo "❌ Error: This script must be run from the app-setup directory"
  echo ""
  echo "Current directory: ${PWD}"
  echo "Script directory:  ${SCRIPT_DIR}"
  echo ""
  echo "Please change to the app-setup directory and try again:"
  echo "  cd $(dirname "${SCRIPT_DIR}")/app-setup"
  echo "  ./$(basename "${0}")"
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "❌ Error: Configuration file not found: ${CONFIG_FILE}"
  echo ""
  echo "Please create config/config.conf from config/config.conf.template"
  exit 1
fi

# shellcheck source=config/config.conf
source "${CONFIG_FILE}"

HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
LAUNCHAGENT_DIR="${OPERATOR_HOME}/Library/LaunchAgents"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

FORCE=false
for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=true ;;
    *)
      echo "❌ Unknown option: ${arg}"
      echo "Usage: $0 [--force]"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-apps.log"
mkdir -p "${LOG_DIR}"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s [podman-transmission] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

section() {
  log ""
  log "=== $1 ==="
}

# ---------------------------------------------------------------------------
# Error and warning collection (same pattern as filebot-setup.sh)
# ---------------------------------------------------------------------------

COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
CURRENT_SCRIPT_SECTION=""

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  log "====== $1 ======"
}

collect_error() {
  local message="$1"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"
  local clean_message
  clean_message="$(printf '%s' "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  printf '❌ %s\n' "${clean_message}"
  log "ERROR: ${clean_message}"
  COLLECTED_ERRORS+=("[${script_name}] ${context}: ${clean_message}")
}

collect_warning() {
  local message="$1"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"
  local clean_message
  clean_message="$(printf '%s' "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  printf '⚠️  %s\n' "${clean_message}"
  log "WARNING: ${clean_message}"
  COLLECTED_WARNINGS+=("[${script_name}] ${context}: ${clean_message}")
}

show_collected_issues() {
  local error_count=${#COLLECTED_ERRORS[@]}
  local warning_count=${#COLLECTED_WARNINGS[@]}

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    log "✅ Podman Transmission setup completed with no errors or warnings"
    return
  fi

  echo ""
  echo "====== PODMAN TRANSMISSION SETUP SUMMARY ======"
  echo "Setup completed with ${error_count} errors and ${warning_count} warnings:"
  echo ""

  if [[ ${error_count} -gt 0 ]]; then
    echo "ERRORS:"
    for err in "${COLLECTED_ERRORS[@]}"; do printf '  %s\n' "${err}"; done
    echo ""
  fi

  if [[ ${warning_count} -gt 0 ]]; then
    echo "WARNINGS:"
    for warn in "${COLLECTED_WARNINGS[@]}"; do printf '  %s\n' "${warn}"; done
    echo ""
  fi

  echo "Review the issues above before starting the container stack."
  log "Setup completed with ${error_count} errors and ${warning_count} warnings"
}

trap 'show_collected_issues' EXIT

# ---------------------------------------------------------------------------
# Confirmation helper
# ---------------------------------------------------------------------------

confirm() {
  local prompt="$1"
  local default="${2:-y}"

  if [[ "${FORCE}" == "true" ]]; then
    [[ "${default}" == "y" ]] && return 0 || return 1
  fi

  if [[ "${default}" == "y" ]]; then
    read -rp "${prompt} (Y/n): " -n 1 response
    echo
    response="${response:-y}"
  else
    read -rp "${prompt} (y/N): " -n 1 response
    echo
    response="${response:-n}"
  fi

  case "${response}" in
    [yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Validate required configuration
# ---------------------------------------------------------------------------

log "Starting Podman Transmission setup for ${SERVER_NAME}"
log "Operator account: ${OPERATOR_USERNAME}"
log "Configuration loaded from: ${CONFIG_FILE}"
[[ "${FORCE}" == "true" ]] && log "Running in force mode (skipping confirmations)"

if [[ -z "${OPERATOR_USERNAME}" ]]; then
  echo "❌ OPERATOR_USERNAME not set in configuration"
  exit 1
fi

# PIA_VPN_REGION and LAN_SUBNET default gracefully if missing from config
PIA_REGION="${PIA_VPN_REGION:-panama}"
LAN="${LAN_SUBNET:-192.168.1.0/24}"

if [[ "${FORCE}" != "true" ]]; then
  echo ""
  echo "This will set up containerized Transmission with:"
  echo "  • Operator account: ${OPERATOR_USERNAME}"
  echo "  • Podman machine:   transmission-vm (rootful)"
  echo "  • PIA VPN region:   ${PIA_REGION}"
  echo "  • LAN subnet:       ${LAN}"
  echo "  • Data mount:       ${OPERATOR_HOME}/.local/mnt/DSMedia"
  echo ""
  if ! confirm "Continue with Podman Transmission setup?" "y"; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Section 1: Install Podman and verify minimum version
# ---------------------------------------------------------------------------

set_section "Podman Installation"

if ! command -v podman >/dev/null 2>&1; then
  log "Installing Podman via Homebrew..."
  brew install podman
fi

PODMAN_VERSION=$(podman --version | awk '{print $3}')
PODMAN_MAJOR=$(cut -d. -f1 <<<"${PODMAN_VERSION}")
PODMAN_MINOR=$(cut -d. -f2 <<<"${PODMAN_VERSION}")

log "Podman version: ${PODMAN_VERSION}"

if [[ "${PODMAN_MAJOR}" -lt 4 ]] \
  || { [[ "${PODMAN_MAJOR}" -eq 4 ]] && [[ "${PODMAN_MINOR}" -lt 7 ]]; }; then
  collect_error "Podman ${PODMAN_VERSION} is too old — need ≥4.7.0 for built-in compose. Run: brew upgrade podman"
  exit 1
fi

log "✅ Podman ${PODMAN_VERSION} meets minimum version requirement (≥4.7.0)"

# ---------------------------------------------------------------------------
# Section 2: Podman machine setup
# ---------------------------------------------------------------------------

set_section "Podman Machine Setup"

MACHINE_EXISTS=false
if sudo -iu "${OPERATOR_USERNAME}" podman machine inspect transmission-vm >/dev/null 2>&1; then
  MACHINE_EXISTS=true
fi

if [[ "${MACHINE_EXISTS}" == "false" ]]; then
  log "Initializing Podman machine 'transmission-vm' (rootful, 2 CPU, 2GB RAM, 20GB disk)..."
  sudo -iu "${OPERATOR_USERNAME}" podman machine init \
    --rootful \
    --cpus 2 \
    --memory 2048 \
    --disk-size 20 \
    transmission-vm
  log "Machine initialized"
else
  log "Machine 'transmission-vm' already exists — skipping init"
fi

# Always set the default connection — this is client-side config and must survive re-runs
sudo -iu "${OPERATOR_USERNAME}" podman system connection default transmission-vm
log "Default Podman connection confirmed: transmission-vm"

MACHINE_STATE=$(sudo -iu "${OPERATOR_USERNAME}" podman machine inspect transmission-vm \
  --format '{{.State}}' 2>/dev/null || echo "unknown")

if [[ "${MACHINE_STATE}" != "running" ]]; then
  log "Starting Podman machine..."
  sudo -iu "${OPERATOR_USERNAME}" podman machine start transmission-vm
  log "Machine started"
else
  log "Machine already running"
fi

# ---------------------------------------------------------------------------
# Section 3: Container directory structure
# ---------------------------------------------------------------------------

set_section "Container Directory Structure"

CONTAINER_DIR="${OPERATOR_HOME}/containers/transmission"
log "Creating container directories under ${CONTAINER_DIR}"

sudo -iu "${OPERATOR_USERNAME}" mkdir -p \
  "${CONTAINER_DIR}" \
  "${CONTAINER_DIR}/config" \
  "${CONTAINER_DIR}/scripts"

sudo chmod 700 "${CONTAINER_DIR}"
sudo chmod 755 "${CONTAINER_DIR}/config" "${CONTAINER_DIR}/scripts"
sudo chown -R "${OPERATOR_USERNAME}:staff" "${CONTAINER_DIR}"

log "✅ Container directories created"

# ---------------------------------------------------------------------------
# Section 4: PIA credentials → .env
# ---------------------------------------------------------------------------

set_section "PIA Credentials"

# Credentials stored as "username:password" combined string per project keychain convention.
# Account field = ${HOSTNAME_LOWER}, service = pia-account-${HOSTNAME_LOWER}.
PIA_CREDS=$(security find-generic-password \
  -s "pia-account-${HOSTNAME_LOWER}" \
  -a "${HOSTNAME_LOWER}" \
  -w 2>/dev/null || true)

ENV_WRITTEN=false
if [[ -z "${PIA_CREDS}" ]]; then
  collect_error "PIA credentials not found in keychain (service: pia-account-${HOSTNAME_LOWER}, account: ${HOSTNAME_LOWER}). Run prep-airdrop.sh with ONEPASSWORD_PIA_ITEM set."
else
  PIA_USERNAME=$(cut -d: -f1 <<<"${PIA_CREDS}")
  PIA_PASSWORD=$(cut -d: -f2- <<<"${PIA_CREDS}")
  unset PIA_CREDS

  ENV_FILE="${CONTAINER_DIR}/.env"
  printf 'PIA_USERNAME=%s\nPIA_PASSWORD=%s\n' "${PIA_USERNAME}" "${PIA_PASSWORD}" \
    | sudo -iu "${OPERATOR_USERNAME}" tee "${ENV_FILE}" >/dev/null
  unset PIA_USERNAME PIA_PASSWORD

  sudo chmod 600 "${ENV_FILE}"
  sudo chown "${OPERATOR_USERNAME}:staff" "${ENV_FILE}"
  ENV_WRITTEN=true
  log "✅ .env written with PIA credentials (mode 600)"
fi

# ---------------------------------------------------------------------------
# Section 5: Deploy compose.yml
# ---------------------------------------------------------------------------

set_section "Deploy compose.yml"

COMPOSE_TEMPLATE="${SCRIPT_DIR}/containers/transmission/compose.yml"
COMPOSE_DEST="${CONTAINER_DIR}/compose.yml"

if [[ ! -f "${COMPOSE_TEMPLATE}" ]]; then
  collect_error "Compose template not found: ${COMPOSE_TEMPLATE}"
else
  # Gather substitution values
  PUID=$(id -u "${OPERATOR_USERNAME}")
  PGID=$(id -g "${OPERATOR_USERNAME}")
  # readlink /etc/localtime gives e.g. /var/db/timezone/zoneinfo/America/Los_Angeles
  TZ_VALUE=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||' || true)
  TZ_VALUE="${TZ_VALUE:-America/Los_Angeles}"

  log "Deploying compose.yml (region: ${PIA_REGION}, LAN: ${LAN}, TZ: ${TZ_VALUE})"

  sudo sed \
    -e "s|__SERVER_NAME__|${HOSTNAME}|g" \
    -e "s|__PIA_VPN_REGION__|${PIA_REGION}|g" \
    -e "s|__LAN_SUBNET__|${LAN}|g" \
    -e "s|__OPERATOR_HOME__|${OPERATOR_HOME}|g" \
    -e "s|__PUID__|${PUID}|g" \
    -e "s|__PGID__|${PGID}|g" \
    -e "s|__TZ__|${TZ_VALUE}|g" \
    "${COMPOSE_TEMPLATE}" | sudo tee "${COMPOSE_DEST}" >/dev/null

  sudo chown "${OPERATOR_USERNAME}:staff" "${COMPOSE_DEST}"
  sudo chmod 644 "${COMPOSE_DEST}"
  log "✅ compose.yml deployed to ${COMPOSE_DEST}"
fi

# ---------------------------------------------------------------------------
# Section 6: Deploy transmission-post-done.sh (container-side trigger)
# ---------------------------------------------------------------------------

set_section "Deploy Container Trigger Script"

POST_DONE_TEMPLATE="${SCRIPT_DIR}/templates/transmission-post-done.sh"
POST_DONE_DEST="${CONTAINER_DIR}/scripts/transmission-post-done.sh"

if [[ ! -f "${POST_DONE_TEMPLATE}" ]]; then
  collect_error "Template not found: ${POST_DONE_TEMPLATE}"
else
  sudo cp "${POST_DONE_TEMPLATE}" "${POST_DONE_DEST}"
  sudo chmod 755 "${POST_DONE_DEST}"
  sudo chown "${OPERATOR_USERNAME}:staff" "${POST_DONE_DEST}"
  log "✅ transmission-post-done.sh deployed to ${POST_DONE_DEST}"
fi

# ---------------------------------------------------------------------------
# Section 7: Deploy transmission-trigger-watcher.sh (macOS LaunchAgent daemon)
# ---------------------------------------------------------------------------

set_section "Deploy Trigger Watcher Script"

WATCHER_TEMPLATE="${SCRIPT_DIR}/templates/transmission-trigger-watcher.sh"
WATCHER_DEST="${OPERATOR_HOME}/.local/bin/transmission-trigger-watcher.sh"

if [[ ! -f "${WATCHER_TEMPLATE}" ]]; then
  collect_error "Template not found: ${WATCHER_TEMPLATE}"
else
  sudo -iu "${OPERATOR_USERNAME}" mkdir -p "$(dirname "${WATCHER_DEST}")"

  sudo sed "s|__SERVER_NAME__|${HOSTNAME}|g" \
    "${WATCHER_TEMPLATE}" | sudo tee "${WATCHER_DEST}" >/dev/null
  sudo chmod 755 "${WATCHER_DEST}"
  sudo chown "${OPERATOR_USERNAME}:staff" "${WATCHER_DEST}"
  log "✅ transmission-trigger-watcher.sh deployed to ${WATCHER_DEST}"
fi

# ---------------------------------------------------------------------------
# Section 8: Deploy podman-machine-start.sh wrapper
# ---------------------------------------------------------------------------

set_section "Deploy Machine Start Wrapper"

MACHINE_START_DEST="${OPERATOR_HOME}/.local/bin/podman-machine-start.sh"

# Write the wrapper directly (values baked in at deploy time).
# Variables prefixed with \ escape into the written script; bare ${...} expand now.
sudo tee "${MACHINE_START_DEST}" >/dev/null <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
#
# podman-machine-start.sh - Start Podman machine and bring up transmission stack
#
# Invoked by com.${HOSTNAME_LOWER}.podman-transmission-vm LaunchAgent at login.
# Ensures the machine is running, waits for the socket, then runs compose up.
# Separate from the setup script so it can be re-run safely at each login.

MACHINE_STATE=\$(podman machine inspect transmission-vm --format '{{.State}}' 2>/dev/null || echo "unknown")
if [[ "\${MACHINE_STATE}" != "running" ]]; then
    podman machine start transmission-vm
fi

# Wait for the Podman socket to become ready (up to 30 seconds)
for _ in {1..30}; do
    if podman info >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

podman compose --project-directory "${OPERATOR_HOME}/containers/transmission" \
    --env-file "${OPERATOR_HOME}/containers/transmission/.env" up -d
WRAPPER

sudo chmod 755 "${MACHINE_START_DEST}"
sudo chown "${OPERATOR_USERNAME}:staff" "${MACHINE_START_DEST}"
log "✅ podman-machine-start.sh deployed to ${MACHINE_START_DEST}"

# ---------------------------------------------------------------------------
# Section 9: Create LaunchAgents
# ---------------------------------------------------------------------------

set_section "Create LaunchAgents"

if [[ ! -d "${LAUNCHAGENT_DIR}" ]]; then
  sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${LAUNCHAGENT_DIR}"
fi

# --- 9a: Podman machine + compose startup agent ---

MACHINE_PLIST="${LAUNCHAGENT_DIR}/com.${HOSTNAME_LOWER}.podman-transmission-vm.plist"
log "Creating LaunchAgent: ${MACHINE_PLIST}"

sudo -iu "${OPERATOR_USERNAME}" tee "${MACHINE_PLIST}" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.podman-transmission-vm</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${OPERATOR_HOME}/.local/bin/podman-machine-start.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-podman-vm-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-podman-vm-stderr.log</string>
</dict>
</plist>
PLIST

sudo chown "${OPERATOR_USERNAME}:staff" "${MACHINE_PLIST}"
sudo chmod 644 "${MACHINE_PLIST}"

if sudo plutil -lint "${MACHINE_PLIST}" >/dev/null 2>&1; then
  log "✅ podman-transmission-vm LaunchAgent created and validated"
else
  collect_error "Invalid plist syntax in ${MACHINE_PLIST} — launchd will reject this agent"
fi

# --- 9b: Trigger watcher daemon ---

WATCHER_PLIST="${LAUNCHAGENT_DIR}/com.${HOSTNAME_LOWER}.transmission-trigger-watcher.plist"
log "Creating LaunchAgent: ${WATCHER_PLIST}"

sudo -iu "${OPERATOR_USERNAME}" tee "${WATCHER_PLIST}" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.transmission-trigger-watcher</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${OPERATOR_HOME}/.local/bin/transmission-trigger-watcher.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-trigger-watcher-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-trigger-watcher-stderr.log</string>
</dict>
</plist>
PLIST

sudo chown "${OPERATOR_USERNAME}:staff" "${WATCHER_PLIST}"
sudo chmod 644 "${WATCHER_PLIST}"

if sudo plutil -lint "${WATCHER_PLIST}" >/dev/null 2>&1; then
  log "✅ transmission-trigger-watcher LaunchAgent created and validated"
else
  collect_error "Invalid plist syntax in ${WATCHER_PLIST} — launchd will reject this agent"
fi

# ---------------------------------------------------------------------------
# Section 10: Validate NAS bind mount through Podman VirtioFS
# ---------------------------------------------------------------------------

set_section "NAS Bind Mount Validation"

NAS_MOUNT="${OPERATOR_HOME}/.local/mnt/DSMedia"
if [[ ! -d "${NAS_MOUNT}" ]]; then
  collect_warning "NAS mount not present at ${NAS_MOUNT} — ensure mount-nas-media LaunchAgent has run. Bind mount validation skipped."
else
  log "Testing NAS bind mount through Podman VirtioFS..."
  TEST_RESULT=$(sudo -iu "${OPERATOR_USERNAME}" podman run --rm \
    -v "${NAS_MOUNT}:/test:ro" \
    alpine ls /test 2>&1) || true

  if [[ -n "${TEST_RESULT}" ]]; then
    log "✅ NAS bind mount: OK — VirtioFS exposes mounted content"
    SAMPLE=$(printf '%s' "${TEST_RESULT}" | head -3 | tr '\n' ' ' || true)
    log "   Sample contents: ${SAMPLE}"
  else
    collect_warning "NAS bind mount: EMPTY — VirtioFS may not see SMB mount content"
    collect_warning "Fallback required: mount SMB from within Podman VM /etc/fstab"
    collect_warning "See docs/container-transmission-proposal.md §5.1 for fallback instructions"
  fi
fi

# ---------------------------------------------------------------------------
# Section 11: Start the container stack
# ---------------------------------------------------------------------------

set_section "Start Container Stack"

ERROR_COUNT=${#COLLECTED_ERRORS[@]}
if [[ "${ERROR_COUNT}" -gt 0 ]]; then
  log "Skipping container start: ${ERROR_COUNT} error(s) must be resolved first"
elif [[ "${ENV_WRITTEN}" == "false" ]]; then
  log "Skipping container start: .env not written (missing PIA credentials)"
else
  log "Starting container stack (podman compose up -d)..."
  if sudo -iu "${OPERATOR_USERNAME}" bash -c \
    "cd '${CONTAINER_DIR}' && podman compose --env-file .env up -d"; then
    log "✅ Container stack started"
    log ""
    log "Verify with:"
    log "  podman logs transmission-vpn"
    log "  podman exec transmission-vpn curl -s ifconfig.io  (should return Panama PIA exit IP)"
    log "  Transmission web UI: http://${HOSTNAME_LOWER}.local:9091"
  else
    collect_error "podman compose up failed — check 'podman logs transmission-vpn' for details"
  fi
fi

log ""
log "Podman Transmission setup complete for ${SERVER_NAME}"
