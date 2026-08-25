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
#   - NAS NFS export configured (enable non-privileged ports for VM NAT traffic)
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

# SERVER_NAME comes from the sourced config. Validate it before deriving
# anything: SERVER_NAME_LOWER names the keychain service the PIA credentials
# are stored under, so an empty value would look up "pia-account-" and report a
# missing-credentials error that points nowhere near the real cause.
SERVER_NAME="${SERVER_NAME:-}"
if [[ -z "${SERVER_NAME}" ]]; then
  echo "❌ SERVER_NAME not set in ${CONFIG_FILE}"
  exit 1
fi

SERVER_NAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
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

# PIA_VPN_REGION and LAN_SUBNET default gracefully if missing from config.
# The PIA_VPN_REGION fallback must stay in step with config.conf.template:
# panama (the pre-2026-08-23 default) serves no port forwarding at all, so
# falling back to it would silently deploy a non-working region.
PIA_REGION="${PIA_VPN_REGION:-ca_vancouver}"
LAN="${LAN_SUBNET:-192.168.1.0/24}"
HOST_PORT="${TRANSMISSION_HOST_PORT:-9091}"

if [[ "${FORCE}" != "true" ]]; then
  echo ""
  echo "This will set up containerized Transmission with:"
  echo "  • Operator account: ${OPERATOR_USERNAME}"
  echo "  • Podman machine:   transmission-vm (rootful)"
  echo "  • PIA VPN region:   ${PIA_REGION}"
  echo "  • LAN subnet:       ${LAN}"
  echo "  • Data mount:       ${OPERATOR_HOME}/.local/mnt/${NAS_SHARE_NAME}"
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
# Section 2b: Data volume path (VirtioFS pass-through from host NFS mount)
# ---------------------------------------------------------------------------

set_section "Data Volume Path"

# Validate required NAS config variables (safe characters only — used in mount path construction)
safe_pattern='^[a-zA-Z0-9._-]+$'
if [[ -z "${NAS_HOSTNAME:-}" ]] || [[ -z "${NAS_SHARE_NAME:-}" ]]; then
  collect_error "NAS_HOSTNAME and NAS_SHARE_NAME must be set in config.conf"
  exit 1
fi
if [[ ! "${NAS_HOSTNAME}" =~ ${safe_pattern} ]] || [[ ! "${NAS_SHARE_NAME}" =~ ${safe_pattern} ]] || [[ ! "${NAS_VOLUME:-volume1}" =~ ${safe_pattern} ]]; then
  collect_error "NAS_HOSTNAME, NAS_SHARE_NAME, and NAS_VOLUME must contain only alphanumeric, dot, hyphen, or underscore"
  exit 1
fi

NFS_MOUNT_POINT="${OPERATOR_HOME}/.local/mnt/${NAS_SHARE_NAME}"

log "Data volume will use VirtioFS pass-through: ${NFS_MOUNT_POINT}"

# ---------------------------------------------------------------------------
# Section 3: Container directory structure
# ---------------------------------------------------------------------------

set_section "Container Directory Structure"

CONTAINER_DIR="${OPERATOR_HOME}/containers/transmission"
log "Creating container directories under ${CONTAINER_DIR}"

sudo -iu "${OPERATOR_USERNAME}" mkdir -p \
  "${CONTAINER_DIR}" \
  "${CONTAINER_DIR}/config" \
  "${CONTAINER_DIR}/scripts" \
  "${CONTAINER_DIR}/watch"

sudo chmod 700 "${CONTAINER_DIR}"
sudo chmod 755 "${CONTAINER_DIR}/config" "${CONTAINER_DIR}/scripts" "${CONTAINER_DIR}/watch"
sudo chown -R "${OPERATOR_USERNAME}:staff" "${CONTAINER_DIR}"

log "✅ Container directories created"

# ---------------------------------------------------------------------------
# Section 4: PIA credentials → .env
# ---------------------------------------------------------------------------

set_section "PIA Credentials"

# Credentials stored as "username:password" combined string per project keychain convention.
# Service and account use SERVER_NAME_LOWER (matches how prep-airdrop.sh stored them).
# HOSTNAME_LOWER may differ when HOSTNAME_OVERRIDE is set; SERVER_NAME_LOWER never does.
PIA_CREDS=$(security find-generic-password \
  -s "pia-account-${SERVER_NAME_LOWER}" \
  -a "${SERVER_NAME_LOWER}" \
  -w 2>/dev/null || true)

ENV_WRITTEN=false
if [[ -z "${PIA_CREDS}" ]]; then
  collect_error "PIA credentials not found in keychain (service: pia-account-${SERVER_NAME_LOWER}, account: ${SERVER_NAME_LOWER}). Run prep-airdrop.sh with ONEPASSWORD_PIA_ITEM set."
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
# Section 5: Gather container environment values
# ---------------------------------------------------------------------------

set_section "Gather container environment values"

PUID=$(id -u "${OPERATOR_USERNAME}")
PGID=$(id -g "${OPERATOR_USERNAME}")
TZ_VALUE=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||' || true)
TZ_VALUE="${TZ_VALUE:-America/Los_Angeles}"

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
# Section 6b: Deploy PIA port forwarding manager (container-side)
# ---------------------------------------------------------------------------

set_section "Deploy PIA Port Forwarding Manager"

# Replaces the image's bundled update-port.sh, which zeroes Transmission's
# listen port when PIA's port-forwarding API is unavailable (issue #159). The
# bundled script cannot be patched in place: it sits in /etc/openvpn/pia/
# alongside the 167 .ovpn region configs, so mounting over that directory to
# swap one file would hide the configs. DISABLE_PORT_UPDATER=true keeps it
# dormant while our version runs from the already-mounted /scripts volume.
PORT_GUARD_TEMPLATE="${SCRIPT_DIR}/templates/pia-port-guard.sh"
PORT_GUARD_DEST="${CONTAINER_DIR}/scripts/pia-port-guard.sh"
POST_START_TEMPLATE="${SCRIPT_DIR}/templates/transmission-post-start.sh"
POST_START_DEST="${CONTAINER_DIR}/scripts/transmission-post-start.sh"

if [[ ! -f "${PORT_GUARD_TEMPLATE}" ]]; then
  collect_error "Template not found: ${PORT_GUARD_TEMPLATE}"
elif [[ ! -f "${POST_START_TEMPLATE}" ]]; then
  collect_error "Template not found: ${POST_START_TEMPLATE}"
else
  # The guard is sourced, not executed, so it does not need the execute bit.
  sudo cp "${PORT_GUARD_TEMPLATE}" "${PORT_GUARD_DEST}"
  sudo chmod 644 "${PORT_GUARD_DEST}"
  sudo chown "${OPERATOR_USERNAME}:staff" "${PORT_GUARD_DEST}"

  sudo cp "${POST_START_TEMPLATE}" "${POST_START_DEST}"
  sudo chmod 755 "${POST_START_DEST}"
  sudo chown "${OPERATOR_USERNAME}:staff" "${POST_START_DEST}"

  log "✅ PIA port forwarding manager deployed (guard + post-start hook)"
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

  sudo sed -e "s|__SERVER_NAME__|${HOSTNAME}|g" \
    -e "s|__TRANSMISSION_HOST_PORT__|${HOST_PORT}|g" \
    -e "s|__NAS_SHARE_NAME__|${NAS_SHARE_NAME}|g" \
    "${WATCHER_TEMPLATE}" | sudo tee "${WATCHER_DEST}" >/dev/null
  sudo chmod 755 "${WATCHER_DEST}"
  sudo chown "${OPERATOR_USERNAME}:staff" "${WATCHER_DEST}"
  log "✅ transmission-trigger-watcher.sh deployed to ${WATCHER_DEST}"
fi

# ---------------------------------------------------------------------------
# Section 7b: Deploy pending-move cleanup script
# ---------------------------------------------------------------------------

set_section "Deploy Pending-Move Cleanup Script"

CLEANUP_TEMPLATE="${SCRIPT_DIR}/templates/pending-move-cleanup.sh"
CLEANUP_DEST="${OPERATOR_HOME}/.local/bin/pending-move-cleanup.sh"

if [[ ! -f "${CLEANUP_TEMPLATE}" ]]; then
  collect_error "Cleanup template not found: ${CLEANUP_TEMPLATE}"
else
  log "Deploying pending-move-cleanup.sh"

  sudo sed \
    -e "s|__SERVER_NAME__|${HOSTNAME}|g" \
    -e "s|__TRANSMISSION_HOST_PORT__|${HOST_PORT}|g" \
    -e "s|__OPERATOR_HOME__|${OPERATOR_HOME}|g" \
    -e "s|__NAS_SHARE_NAME__|${NAS_SHARE_NAME}|g" \
    "${CLEANUP_TEMPLATE}" | sudo tee "${CLEANUP_DEST}" >/dev/null

  sudo chown "${OPERATOR_USERNAME}:staff" "${CLEANUP_DEST}"
  sudo chmod 755 "${CLEANUP_DEST}"
  log "✅ pending-move-cleanup.sh deployed"
fi

# ---------------------------------------------------------------------------
# Section 7b: Deploy PIA port forwarding watchdog
# ---------------------------------------------------------------------------

set_section "Deploy PIA Port Watchdog"

PORT_WATCHDOG_TEMPLATE="${SCRIPT_DIR}/templates/pia-port-watchdog.sh"
PORT_WATCHDOG_DEST="${OPERATOR_HOME}/.local/bin/pia-port-watchdog.sh"
PORT_WATCHDOG_MSMTP="${OPERATOR_HOME}/.config/msmtp/config"

# The watchdog alerts by email, so it needs both a destination address and a
# configured msmtp. Neither is set up by this script — msmtp-setup.sh owns
# that — so skip rather than deploying an agent that can only log failures to
# send mail. This script also runs unattended, so prompting is not an option.
PORT_WATCHDOG_DEPLOY=true
if [[ -z "${MONITORING_EMAIL:-}" ]] || [[ "${MONITORING_EMAIL}" == "your-email@example.com" ]]; then
  log "⏭️  Skipping PIA port watchdog: MONITORING_EMAIL not configured in ${CONFIG_FILE}"
  PORT_WATCHDOG_DEPLOY=false
elif [[ ! -f "${PORT_WATCHDOG_MSMTP}" ]]; then
  log "⏭️  Skipping PIA port watchdog: msmtp not configured. Run msmtp-setup.sh, then re-run this script."
  PORT_WATCHDOG_DEPLOY=false
elif [[ ! -f "${PORT_WATCHDOG_TEMPLATE}" ]]; then
  collect_error "PIA port watchdog template not found: ${PORT_WATCHDOG_TEMPLATE}"
  PORT_WATCHDOG_DEPLOY=false
fi

if [[ "${PORT_WATCHDOG_DEPLOY}" == "true" ]]; then
  log "Deploying pia-port-watchdog.sh"

  sudo sed \
    -e "s|__SERVER_NAME__|${HOSTNAME}|g" \
    -e "s|__MONITORING_EMAIL__|${MONITORING_EMAIL}|g" \
    -e "s|__TRANSMISSION_HOST_PORT__|${HOST_PORT}|g" \
    "${PORT_WATCHDOG_TEMPLATE}" | sudo tee "${PORT_WATCHDOG_DEST}" >/dev/null

  sudo chown "${OPERATOR_USERNAME}:staff" "${PORT_WATCHDOG_DEST}"
  sudo chmod 755 "${PORT_WATCHDOG_DEST}"
  log "✅ pia-port-watchdog.sh deployed"
fi

# ---------------------------------------------------------------------------
# Section 8: Deploy podman-machine-start.sh wrapper
# ---------------------------------------------------------------------------

set_section "Deploy Machine Start Wrapper"

MACHINE_START_DEST="${OPERATOR_HOME}/.local/bin/podman-machine-start.sh"

# Write the wrapper directly (values baked in at deploy time).
# Variables prefixed with \ escape into the written script; bare ${...} expand now.
# Required variables (all defined earlier): NFS_MOUNT_POINT (Section 2b), OPERATOR_HOME (line ~88),
# HOST_PORT (line ~240), PIA_REGION (line ~238), LAN (line ~239), PUID/PGID (Section 5), TZ_VALUE (Section 5)
sudo tee "${MACHINE_START_DEST}" >/dev/null <<WRAPPER
#!/usr/bin/env bash
set -uo pipefail
#
# podman-machine-start.sh - Start Podman machine and supervise the transmission stack
#
# Invoked by com.${HOSTNAME_LOWER}.podman-transmission-vm LaunchAgent at login.
#
# This script DOES NOT EXIT under normal operation. After starting the VM and
# creating the container, it enters a supervision loop that sleeps between
# health checks. Exiting would make launchd dissolve the LaunchAgent's resource
# coalition, which in turn causes vfkit (the Apple-hypervisor VM process) to
# receive XPC_ERROR_CONNECTION_INTERRUPTED and cleanly shut down about 5
# seconds later. Observed on TILSIT after the 2026-04-18 reboot.
#
# Maintenance:
#   launchctl bootout gui/\$(id -u)/com.${HOSTNAME_LOWER}.podman-transmission-vm
#   podman machine stop transmission-vm
# Reverse with 'launchctl bootstrap gui/<uid> <plist>' or reboot.

export PATH="${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SUPERVISE_INTERVAL=\${SUPERVISE_INTERVAL:-300}

log_ts() {
    local ts
    ts=\$(date '+%F %T' 2>/dev/null || echo "-")
    echo "[\${ts}] \$*"
}

# Every podman call in this script goes through podman_t (issue #168).
#
# On 2026-08-16 a routine VirtioFS recovery issued \`podman run -d\` through a
# freshly Homebrew-upgraded 6.1.0 CLI while a leftover 6.0.2 gvproxy still held
# the machine's socket paths. That podman run hung indefinitely — it was still
# running 27 hours later. Because this supervision loop is single-threaded and
# calls ensure_container synchronously, the hang froze the whole loop: no
# further log lines, no container, nothing listening on the web UI port, and no
# self-recovery, which is precisely what the loop exists to provide.
#
# A hung subprocess must never be able to do that again. Any podman invocation
# that exceeds its timeout is killed and reported as a distinct failure, which
# the callers treat like any other failure: retry next cycle.
PODMAN_CMD_TIMEOUT=\${PODMAN_CMD_TIMEOUT:-60}
PODMAN_MACHINE_TIMEOUT=\${PODMAN_MACHINE_TIMEOUT:-180}

# timeout(1) exits 124 when it had to kill the command.
TIMEOUT_RC=124

# timeout(1) comes from coreutils, which config/formulae.txt installs, and it
# is required rather than optional. Two considered fallbacks were rejected:
#
#   - Running unbounded when it is missing reintroduces exactly the hang this
#     section exists to prevent, and does so silently.
#   - perl's \`alarm shift; exec @ARGV\` does not work here. SIGALRM kills the
#     perl process but leaves the command's own children running, so they hold
#     the command-substitution pipe open and \`state=\$(podman_t ... inspect)\`
#     blocks forever anyway — the original bug, wearing a timeout.
#
# So: fail loudly at startup instead of supervising with a supervision loop
# that cannot actually recover.
if ! command -v timeout >/dev/null 2>&1; then
    log_ts "FATAL: timeout(1) not found on PATH."
    log_ts "It is required to bound podman calls; without it a hung podman"
    log_ts "command freezes this supervision loop indefinitely (issue #168)."
    log_ts "Install it with: brew install coreutils"
    exit 1
fi

# Run podman under a timeout. First argument is the timeout in seconds.
# A timeout is logged distinctly from an ordinary non-zero exit so an operator
# reading the log can tell a hang from a failure — not being able to make that
# distinction is what let the August outage run for 27 hours.
podman_t() {
    local limit="\$1"
    shift
    # Just the subcommand for the log. \`podman run\` carries forty-odd flags and
    # printing all of them buries the one fact that matters.
    local what="\$1 \${2:-}"
    local rc=0
    # --kill-after: if podman ignores SIGTERM, SIGKILL follows. Without it a
    # podman that traps TERM keeps the pipe open and the loop stays stuck.
    timeout --kill-after=10 "\${limit}" podman "\$@" || rc=\$?
    if [[ \${rc} -eq \${TIMEOUT_RC} ]]; then
        log_ts "TIMEOUT: 'podman \${what}' exceeded \${limit}s and was killed"
    fi
    return \${rc}
}

# \`podman machine stop\` returning 0 does not mean the machine's helper
# processes are gone. The 6.0.2 gvproxy orphaned by the August incident was
# still running 7 days after the upgrade, holding the socket paths the new CLI
# then tried to reuse. Verify the processes actually exited, and kill whatever
# is left before anything tries to start the machine again.
reap_machine_helpers() {
    local pids
    # Match on the machine name, which appears in both helpers' socket paths
    # (transmission-vm-gvproxy.sock, transmission-vm-api.sock).
    pids=\$(pgrep -f 'gvproxy|vfkit' 2>/dev/null | while read -r pid; do
        if ps -o args= -p "\${pid}" 2>/dev/null | grep -q 'transmission-vm'; then
            echo "\${pid}"
        fi
    done)

    [[ -n "\${pids}" ]] || return 0

    log_ts "stale machine helpers still running after stop: \${pids//\$'\\n'/ }"
    local pid
    for pid in \${pids}; do
        kill "\${pid}" 2>/dev/null || true
    done
    sleep 3
    for pid in \${pids}; do
        if kill -0 "\${pid}" 2>/dev/null; then
            log_ts "helper \${pid} ignored SIGTERM — sending SIGKILL"
            kill -9 "\${pid}" 2>/dev/null || true
        fi
    done
}

wait_for_nfs() {
    local mount_point="${NFS_MOUNT_POINT}"
    local max_wait=120
    local elapsed=0
    while ! /sbin/mount | grep -q " on \${mount_point} "; do
        log_ts "waiting for NFS mount at \${mount_point} (\${elapsed}/\${max_wait}s)..."
        sleep 5
        elapsed=\$((elapsed + 5))
        if (( elapsed >= max_wait )); then
            log_ts "FATAL: NFS mount not available at \${mount_point} after \${max_wait}s"
            return 1
        fi
    done
    log_ts "NFS mount ready at \${mount_point}"
}

ensure_machine() {
    local state
    state=\$(podman_t "\${PODMAN_CMD_TIMEOUT}" machine inspect transmission-vm --format '{{.State}}' 2>/dev/null || echo unknown)
    if [[ "\${state}" != "running" ]]; then
        log_ts "machine state=\${state}, starting transmission-vm"
        # A machine that is not running may still have orphaned helpers holding
        # its sockets — that is exactly the state the August incident started
        # from. Clear them before asking podman to start it.
        reap_machine_helpers
        podman_t "\${PODMAN_MACHINE_TIMEOUT}" machine start transmission-vm || return 1
    fi
    for _ in {1..30}; do
        if podman_t "\${PODMAN_CMD_TIMEOUT}" info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    log_ts "podman socket did not become ready within 30s"
    return 1
}

ensure_container() {
    local running=false
    if podman_t "\${PODMAN_CMD_TIMEOUT}" container exists transmission-vpn 2>/dev/null; then
        running=\$(podman_t "\${PODMAN_CMD_TIMEOUT}" inspect transmission-vpn --format '{{.State.Running}}' 2>/dev/null || echo false)
    fi
    if [[ "\${running}" == "true" ]]; then
        return 0
    fi
    log_ts "container transmission-vpn not running — (re)creating"
    podman_t "\${PODMAN_CMD_TIMEOUT}" rm -f transmission-vpn >/dev/null 2>&1 || true
    podman_t "\${PODMAN_MACHINE_TIMEOUT}" run -d \\
        --name transmission-vpn \\
        --privileged \\
        --device /dev/net/tun:/dev/net/tun \\
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \\
        -v "${NFS_MOUNT_POINT}:/data" \\
        -v "${OPERATOR_HOME}/containers/transmission/scripts:/scripts" \\
        -v "${OPERATOR_HOME}/containers/transmission/config:/config" \\
        -v "${OPERATOR_HOME}/containers/transmission/watch:/watch" \\
        -p "${HOST_PORT}:9091" \\
        --restart unless-stopped \\
        --health-cmd "curl -sf --max-time 5 http://localhost:9091/transmission/web/" \\
        --health-interval 60s \\
        --health-start-period 120s \\
        --health-retries 3 \\
        --health-on-failure restart \\
        --env-file "${OPERATOR_HOME}/containers/transmission/.env" \\
        -e OPENVPN_PROVIDER=PIA \\
        -e "OPENVPN_CONFIG=${PIA_REGION}" \\
        -e "DISABLE_PORT_UPDATER=true" \\
        -e "TRANSMISSION_PEER_PORT_RANDOM_ON_START=false" \\
        -e "LOCAL_NETWORK=${LAN}" \\
        -e "PUID=${PUID}" \\
        -e "PGID=${PGID}" \\
        -e "TZ=${TZ_VALUE}" \\
        -e TRANSMISSION_DOWNLOAD_DIR=/data/Media/Torrents/pending-move \\
        -e TRANSMISSION_INCOMPLETE_DIR_ENABLED=false \\
        -e TRANSMISSION_WATCH_DIR=/watch \\
        -e TRANSMISSION_WATCH_DIR_ENABLED=true \\
        -e TRANSMISSION_RATIO_LIMIT_ENABLED=false \\
        -e TRANSMISSION_ENCRYPTION=1 \\
        -e TRANSMISSION_BLOCKLIST_ENABLED=false \\
        -e TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false \\
        -e TRANSMISSION_RPC_WHITELIST_ENABLED=false \\
        -e TRANSMISSION_SCRIPT_TORRENT_DONE_ENABLED=true \\
        -e TRANSMISSION_SCRIPT_TORRENT_DONE_FILENAME=/scripts/transmission-post-done.sh \\
        -e CREATE_TUN_DEVICE=false \\
        -e LOG_TO_STDOUT=true \\
        haugene/transmission-openvpn:latest
}

DATA_CHECK_FAILURES=0
MAX_DATA_FAILURES=3

check_data_access() {
    if ! podman_t "\${PODMAN_CMD_TIMEOUT}" exec transmission-vpn ls /data/ >/dev/null 2>&1; then
        DATA_CHECK_FAILURES=\$((DATA_CHECK_FAILURES + 1))
        log_ts "WARNING: /data/ inaccessible inside container (failure \${DATA_CHECK_FAILURES}/\${MAX_DATA_FAILURES})"
        if (( DATA_CHECK_FAILURES >= MAX_DATA_FAILURES )); then
            log_ts "RECOVERY: cycling VM to refresh VirtioFS NFS handles"
            podman_t "\${PODMAN_CMD_TIMEOUT}" stop transmission-vpn 2>/dev/null || true
            podman_t "\${PODMAN_CMD_TIMEOUT}" rm -f transmission-vpn 2>/dev/null || true
            podman_t "\${PODMAN_MACHINE_TIMEOUT}" machine stop transmission-vm 2>/dev/null || true
            sleep 5
            # A clean exit status from machine stop is not proof the helpers
            # exited; confirm before restarting into the same socket paths.
            reap_machine_helpers
            if ensure_machine && ensure_container; then
                log_ts "RECOVERY: VM and container restarted successfully"
            else
                log_ts "RECOVERY: restart failed — will retry next cycle"
            fi
            DATA_CHECK_FAILURES=0
        fi
        return 1
    fi
    if (( DATA_CHECK_FAILURES > 0 )); then
        log_ts "data access restored after \${DATA_CHECK_FAILURES} failure(s)"
    fi
    DATA_CHECK_FAILURES=0
    return 0
}

wait_for_nfs || exit 1

# Check these on the way in rather than pressing on regardless. A failed
# machine start followed by an attempted container create produces a confusing
# log — the container error looks like the problem when the machine was.
if ensure_machine; then
    ensure_container || log_ts "initial ensure_container failed — supervision loop will retry"
else
    log_ts "initial ensure_machine failed — supervision loop will retry"
fi

log_ts "entering supervision loop (interval=\${SUPERVISE_INTERVAL}s)"
while true; do
    sleep "\${SUPERVISE_INTERVAL}"
    if ensure_machine; then
        if ensure_container; then
            check_data_access || log_ts "data access check failed — will retry next cycle"
        else
            log_ts "ensure_container failed — will retry next cycle"
        fi
    else
        log_ts "ensure_machine failed — will retry next cycle"
    fi
done
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
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
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

# --- 9c: Pending-move cleanup timer ---

CLEANUP_PLIST="${LAUNCHAGENT_DIR}/com.${HOSTNAME_LOWER}.pending-move-cleanup.plist"
log "Creating LaunchAgent: ${CLEANUP_PLIST}"

sudo -iu "${OPERATOR_USERNAME}" tee "${CLEANUP_PLIST}" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.pending-move-cleanup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${OPERATOR_HOME}/.local/bin/pending-move-cleanup.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-pending-move-cleanup.log</string>
  <key>StandardErrorPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-pending-move-cleanup.log</string>
</dict>
</plist>
PLIST

sudo chown "${OPERATOR_USERNAME}:staff" "${CLEANUP_PLIST}"
sudo chmod 644 "${CLEANUP_PLIST}"

if sudo plutil -lint "${CLEANUP_PLIST}" >/dev/null 2>&1; then
  log "✅ pending-move-cleanup LaunchAgent created (hourly)"
else
  collect_error "Invalid plist syntax in ${CLEANUP_PLIST}"
fi

# --- 9d: PIA port forwarding watchdog timer ---

if [[ "${PORT_WATCHDOG_DEPLOY}" == "true" ]]; then
  PORT_WATCHDOG_PLIST="${LAUNCHAGENT_DIR}/com.${HOSTNAME_LOWER}.pia-port-watchdog.plist"
  log "Creating LaunchAgent: ${PORT_WATCHDOG_PLIST}"

  # 15 minutes matches the port forwarding manager's own refresh cadence, so a
  # loss is noticed within roughly one refresh cycle. With the 3-poll threshold
  # that is a 45-minute worst case before alerting — against the 47 hours the
  # August outage went unnoticed.
  sudo -iu "${OPERATOR_USERNAME}" tee "${PORT_WATCHDOG_PLIST}" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.pia-port-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${OPERATOR_HOME}/.local/bin/pia-port-watchdog.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>900</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-pia-port-watchdog.log</string>
  <key>StandardErrorPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-pia-port-watchdog.log</string>
</dict>
</plist>
PLIST

  sudo chown "${OPERATOR_USERNAME}:staff" "${PORT_WATCHDOG_PLIST}"
  sudo chmod 644 "${PORT_WATCHDOG_PLIST}"

  if sudo plutil -lint "${PORT_WATCHDOG_PLIST}" >/dev/null 2>&1; then
    log "✅ pia-port-watchdog LaunchAgent created (every 15 minutes)"
  else
    collect_error "Invalid plist syntax in ${PORT_WATCHDOG_PLIST}"
  fi
fi

# ---------------------------------------------------------------------------
# Section 10: Validate NAS bind mount through Podman VirtioFS
# ---------------------------------------------------------------------------

set_section "NAS Bind Mount Validation"

NAS_MOUNT="${OPERATOR_HOME}/.local/mnt/${NAS_SHARE_NAME}"
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
  log "Starting container (podman run)..."

  # Remove old container if exists (idempotent)
  sudo -iu "${OPERATOR_USERNAME}" podman rm -f transmission-vpn 2>/dev/null || true

  if sudo -iu "${OPERATOR_USERNAME}" podman run -d \
    --name transmission-vpn \
    --privileged \
    --device /dev/net/tun:/dev/net/tun \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    -v "${NFS_MOUNT_POINT}:/data" \
    -v "${CONTAINER_DIR}/scripts:/scripts" \
    -v "${CONTAINER_DIR}/config:/config" \
    -v "${CONTAINER_DIR}/watch:/watch" \
    -p "${HOST_PORT}:9091" \
    --restart unless-stopped \
    --health-cmd "curl -sf --max-time 5 http://localhost:9091/transmission/web/" \
    --health-interval 60s \
    --health-start-period 120s \
    --health-retries 3 \
    --health-on-failure restart \
    --env-file "${CONTAINER_DIR}/.env" \
    -e OPENVPN_PROVIDER=PIA \
    -e "OPENVPN_CONFIG=${PIA_REGION}" \
    -e "DISABLE_PORT_UPDATER=true" \
    -e "TRANSMISSION_PEER_PORT_RANDOM_ON_START=false" \
    -e "LOCAL_NETWORK=${LAN}" \
    -e "PUID=${PUID}" \
    -e "PGID=${PGID}" \
    -e "TZ=${TZ_VALUE}" \
    -e TRANSMISSION_DOWNLOAD_DIR=/data/Media/Torrents/pending-move \
    -e TRANSMISSION_INCOMPLETE_DIR_ENABLED=false \
    -e TRANSMISSION_WATCH_DIR=/watch \
    -e TRANSMISSION_WATCH_DIR_ENABLED=true \
    -e TRANSMISSION_RATIO_LIMIT_ENABLED=false \
    -e TRANSMISSION_ENCRYPTION=1 \
    -e TRANSMISSION_BLOCKLIST_ENABLED=false \
    -e TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false \
    -e TRANSMISSION_RPC_WHITELIST_ENABLED=false \
    -e TRANSMISSION_SCRIPT_TORRENT_DONE_ENABLED=true \
    -e TRANSMISSION_SCRIPT_TORRENT_DONE_FILENAME=/scripts/transmission-post-done.sh \
    -e CREATE_TUN_DEVICE=false \
    -e LOG_TO_STDOUT=true \
    haugene/transmission-openvpn:latest; then
    log "✅ Container started"
    log ""
    log "Verify with:"
    log "  podman logs transmission-vpn"
    log "  podman exec transmission-vpn curl -s ifconfig.io  (should return Panama PIA exit IP)"
    log "  Transmission web UI: http://${HOSTNAME_LOWER}.local:${HOST_PORT}"
  else
    collect_error "podman run failed — check 'podman logs transmission-vpn' for details"
  fi
fi

# ---------------------------------------------------------------------------
# Section 12: macOS magnet link handler
# ---------------------------------------------------------------------------

set_section "Magnet Link Handler"

MAGNET_HELPER="${OPERATOR_HOME}/.local/bin/transmission-add-magnet.sh"
MAGNET_APP="${OPERATOR_HOME}/Applications/TransmissionMagnetHandler.app"
MAGNET_BUNDLE_ID="com.${HOSTNAME_LOWER}.transmission-magnet-handler"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Ensure .local/bin exists (idempotent; also created by Section 7, but guard here too)
sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_HOME}/.local/bin"

# Deploy the shell helper that handles Transmission RPC.
# HOST_PORT is baked in at deploy time; all other variables are runtime.
sudo tee "${MAGNET_HELPER}" >/dev/null <<MAGNET_HELPER_EOF
#!/usr/bin/env bash
set -euo pipefail
# transmission-add-magnet.sh — Add a magnet URL to Transmission via RPC.
# Called by TransmissionMagnetHandler.app when macOS opens a magnet: link.

MAGNET_URL="\$1"
RPC_URL="http://localhost:${HOST_PORT}/transmission/rpc"

# Transmission's CSRF protection requires a session token from a 409 response.
# Anchor to ^ so the <code> body line in the 409 HTML doesn't also match; exit
# after the first match to avoid a multiline SESSION_ID from the duplicate.
SESSION_ID=\$(curl -s -D - "\${RPC_URL}" 2>/dev/null | \
  awk 'tolower(\$0) ~ /^x-transmission-session-id:/{gsub(/\r/,""); print \$2; exit}')

if [[ -z "\${SESSION_ID}" ]]; then
  osascript -e "display notification \"Could not connect to Transmission (port ${HOST_PORT})\" with title \"Transmission\""
  exit 1
fi

RESPONSE=\$(curl -s "\${RPC_URL}" \
  -H "X-Transmission-Session-Id: \${SESSION_ID}" \
  --data-raw "{\"method\":\"torrent-add\",\"arguments\":{\"filename\":\"\${MAGNET_URL}\"}}")

if echo "\${RESPONSE}" | grep -q '"result":"success"'; then
  osascript -e "display notification \"Magnet link added to Transmission\" with title \"Transmission\""
else
  osascript -e "display notification \"Failed to add magnet link — check Transmission\" with title \"Transmission\""
  exit 1
fi
MAGNET_HELPER_EOF

sudo chmod 755 "${MAGNET_HELPER}"
sudo chown "${OPERATOR_USERNAME}:staff" "${MAGNET_HELPER}"
log "✅ transmission-add-magnet.sh deployed to ${MAGNET_HELPER}"

# Compile AppleScript app that delegates to the shell helper
APPSRC=$(mktemp /tmp/transmission-magnet-XXXXXX.applescript)
chmod 644 "${APPSRC}"
cat >"${APPSRC}" <<APPLESCRIPT_EOF
on open location this_URL
    do shell script (quoted form of "${MAGNET_HELPER}") & " " & quoted form of this_URL
end open location
APPLESCRIPT_EOF

# Remove any previous version before recompiling (idempotent)
if [[ -d "${MAGNET_APP}" ]]; then
  sudo rm -rf "${MAGNET_APP}"
fi

sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${OPERATOR_HOME}/Applications"
if sudo -iu "${OPERATOR_USERNAME}" osacompile -o "${MAGNET_APP}" "${APPSRC}"; then
  rm -f "${APPSRC}"

  # Inject bundle identifier and URL scheme into the compiled app's Info.plist
  MAGNET_PLIST="${MAGNET_APP}/Contents/Info.plist"
  sudo /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${MAGNET_BUNDLE_ID}" "${MAGNET_PLIST}" 2>/dev/null \
    || sudo /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${MAGNET_BUNDLE_ID}" "${MAGNET_PLIST}"
  sudo /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "${MAGNET_PLIST}" 2>/dev/null || true
  sudo /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "${MAGNET_PLIST}" 2>/dev/null || true
  sudo /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "${MAGNET_PLIST}" 2>/dev/null || true
  sudo /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string magnet" "${MAGNET_PLIST}" 2>/dev/null || true
  sudo /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string BitTorrent Magnet Link" "${MAGNET_PLIST}" 2>/dev/null || true
  sudo chown -R "${OPERATOR_USERNAME}:staff" "${MAGNET_APP}"
  log "✅ TransmissionMagnetHandler.app compiled (bundle: ${MAGNET_BUNDLE_ID})"

  # Register with Launch Services and set as default magnet: handler
  sudo -iu "${OPERATOR_USERNAME}" "${LSREGISTER}" -f "${MAGNET_APP}"

  magnet_handler_plist='{
    LSHandlerURLScheme = "magnet";
    LSHandlerRoleAll = "'"${MAGNET_BUNDLE_ID}"'";
    LSHandlerPreferredVersions = {
        LSHandlerRoleAll = "-";
    };
}'
  # Guard -array-add with an existence check to preserve idempotency — re-running
  # without this check would accumulate duplicate entries in LSHandlers.
  if sudo -iu "${OPERATOR_USERNAME}" defaults read \
    com.apple.LaunchServices/com.apple.launchservices.secure \
    LSHandlers 2>/dev/null | grep -q "${MAGNET_BUNDLE_ID}"; then
    log "Magnet link handler already registered — skipping"
  else
    sudo -iu "${OPERATOR_USERNAME}" defaults write \
      com.apple.LaunchServices/com.apple.launchservices.secure \
      LSHandlers -array-add "${magnet_handler_plist}"
    log "✅ Magnet link handler registered: ${MAGNET_BUNDLE_ID} → ${OPERATOR_USERNAME}"
  fi
else
  rm -f "${APPSRC}"
  collect_error "Failed to compile TransmissionMagnetHandler.app — magnet links will not be handled"
fi

log ""
log "Podman Transmission setup complete for ${SERVER_NAME}"
