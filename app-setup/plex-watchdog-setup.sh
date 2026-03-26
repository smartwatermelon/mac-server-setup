#!/usr/bin/env bash
#
# plex-watchdog-setup.sh - Plex settings drift watchdog setup
#
# Deploys a polling daemon that monitors Plex server preferences against a
# golden configuration and sends email alerts on drift. Also deploys a CLI
# tool (plex-watchdog-ctl) for accepting or reverting changes.
#
# Prerequisites:
#   - msmtp configured (run msmtp-setup.sh first)
#   - Plex running and accessible on localhost:32400
#   - Plex token available in /Users/operator/.config/transmission-done/config.yml
#
# Usage: ./plex-watchdog-setup.sh [--force]
#   --force: Skip all confirmation prompts, redeploy even if files exist
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-03-25

set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate working directory
if [[ "${PWD}" != "${SCRIPT_DIR}" ]] || [[ "$(basename "${SCRIPT_DIR}")" != "app-setup" ]]; then
  echo "Error: This script must be run from the app-setup directory"
  echo ""
  echo "Current directory: ${PWD}"
  echo "Script directory: ${SCRIPT_DIR}"
  echo ""
  echo "Please change to the app-setup directory and try again:"
  echo "  cd \"${SCRIPT_DIR}\" && ./plex-watchdog-setup.sh"
  echo ""
  exit 1
fi

# Load server configuration
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
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
LAUNCHAGENT_DIR="${OPERATOR_HOME}/Library/LaunchAgents"

# Logging
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-plex-watchdog-setup.log"
mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

show_log() {
  echo "$*" | tee -a "${LOG_FILE}"
}

section() {
  echo ""
  show_log "=================================================================================="
  show_log "$1"
  show_log "=================================================================================="
  echo ""
}

# Error and warning collection
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
CURRENT_SCRIPT_SECTION=""

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

collect_error() {
  local message="$1"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  log "Error: ${clean_message}"
  COLLECTED_ERRORS+=("[${context}] ${clean_message}")
}

collect_warning() {
  local message="$1"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  log "Warning: ${clean_message}"
  COLLECTED_WARNINGS+=("[${context}] ${clean_message}")
}

show_collected_issues() {
  local error_count=${#COLLECTED_ERRORS[@]}
  local warning_count=${#COLLECTED_WARNINGS[@]}

  if [[ ${error_count} -eq 0 && ${warning_count} -eq 0 ]]; then
    log "Plex watchdog setup completed successfully with no errors or warnings!"
    return
  fi

  log ""
  log "====== PLEX WATCHDOG SETUP SUMMARY ======"
  log "Setup completed with ${error_count} errors and ${warning_count} warnings:"
  log ""

  if [[ ${error_count} -gt 0 ]]; then
    log "ERRORS:"
    for error in "${COLLECTED_ERRORS[@]}"; do
      log "  ${error}"
    done
  fi

  if [[ ${warning_count} -gt 0 ]]; then
    log "WARNINGS:"
    for warning in "${COLLECTED_WARNINGS[@]}"; do
      log "  ${warning}"
    done
  fi
}

trap 'show_collected_issues' EXIT

# Parse command line arguments
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--force]"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Section 1: Prerequisites
# ---------------------------------------------------------------------------

set_section "Prerequisites"

# Validate MONITORING_EMAIL — prompt if not configured
if [[ -z "${MONITORING_EMAIL:-}" ]] || [[ "${MONITORING_EMAIL}" == "your-email@example.com" ]]; then
  echo ""
  echo "MONITORING_EMAIL is not configured in ${CONFIG_FILE}"
  read -r -p "Enter the email address for monitoring alerts: " MONITORING_EMAIL
  echo ""

  if [[ -z "${MONITORING_EMAIL}" ]]; then
    collect_error "No email address provided"
    exit 1
  fi

  sed -i '' "s|^MONITORING_EMAIL=.*|MONITORING_EMAIL=\"${MONITORING_EMAIL}\"|" "${CONFIG_FILE}"
  log "Updated MONITORING_EMAIL in ${CONFIG_FILE}"
fi
log "MONITORING_EMAIL: ${MONITORING_EMAIL}"

# Check msmtp is configured
MSMTP_CONFIG="${OPERATOR_HOME}/.config/msmtp/config"
if [[ ! -f "${MSMTP_CONFIG}" ]]; then
  collect_error "msmtp not configured. Run msmtp-setup.sh first."
  exit 1
fi
log "msmtp config found at ${MSMTP_CONFIG}"

# Check required tools
for tool in xmllint jq curl; do
  if ! command -v "${tool}" &>/dev/null; then
    collect_error "${tool} not found — required for plex-watchdog"
    exit 1
  fi
done
log "Required tools available: xmllint, jq, curl"

# Verify Plex is running and reachable
if curl -sf --max-time 10 "http://localhost:32400/identity" >/dev/null 2>&1; then
  log "Plex is running and reachable"
else
  collect_error "Plex is not reachable at http://localhost:32400. Ensure Plex is running."
  exit 1
fi

# ---------------------------------------------------------------------------
# Section 2: Store Plex token
# ---------------------------------------------------------------------------

set_section "Plex Token"

WATCHDOG_CONFIG_DIR="${OPERATOR_HOME}/.config/plex-watchdog"
PLEX_TOKEN_FILE="${WATCHDOG_CONFIG_DIR}/token"

# Read token from transmission-done config (seed source)
TRANSMISSION_CONFIG="${OPERATOR_HOME}/.config/transmission-done/config.yml"
if [[ ! -f "${TRANSMISSION_CONFIG}" ]]; then
  collect_error "Plex token source not found at ${TRANSMISSION_CONFIG}"
  exit 1
fi

PLEX_TOKEN=$(grep 'token:' "${TRANSMISSION_CONFIG}" | sed 's/.*token:[[:space:]]*//' | tr -d '[:space:]')
if [[ -z "${PLEX_TOKEN}" ]]; then
  collect_error "Could not extract Plex token from ${TRANSMISSION_CONFIG}"
  exit 1
fi

# Verify token works (use header to avoid leaking token in process list)
if curl -sf --max-time 10 -H "X-Plex-Token: ${PLEX_TOKEN}" "http://localhost:32400/identity" >/dev/null 2>&1; then
  log "Plex token verified"
else
  collect_error "Plex token from ${TRANSMISSION_CONFIG} is invalid or expired"
  exit 1
fi

# Deploy token file (mode 600, owned by operator)
sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${WATCHDOG_CONFIG_DIR}"
echo "${PLEX_TOKEN}" | sudo tee "${PLEX_TOKEN_FILE}" >/dev/null
sudo chown "${OPERATOR_USERNAME}:staff" "${PLEX_TOKEN_FILE}"
sudo chmod 600 "${PLEX_TOKEN_FILE}"
log "Plex token stored at ${PLEX_TOKEN_FILE} (mode 600, owner: ${OPERATOR_USERNAME})"

# Token still needed for golden config generation in Section 4.
# Redacted after all uses are complete (end of Section 4).

# ---------------------------------------------------------------------------
# Section 3: Deploy scripts
# ---------------------------------------------------------------------------

set_section "Deploy Scripts"

TEMPLATE_DIR="${SCRIPT_DIR}/templates"
WATCHDOG_DEST="${OPERATOR_HOME}/.local/bin/plex-watchdog"
CTL_DEST="${OPERATOR_HOME}/.local/bin/plex-watchdog-ctl"

sudo -iu "${OPERATOR_USERNAME}" mkdir -p "$(dirname "${WATCHDOG_DEST}")"

# Check for existing deployment
if [[ -f "${WATCHDOG_DEST}" ]] && [[ "${FORCE}" != "true" ]]; then
  log "Watchdog already deployed at ${WATCHDOG_DEST} — use --force to overwrite"
  collect_warning "Existing deployment found. Continuing will overwrite scripts but preserve golden config."
fi

# Deploy plex-watchdog
WATCHDOG_TEMPLATE="${TEMPLATE_DIR}/plex-watchdog.sh"
if [[ ! -f "${WATCHDOG_TEMPLATE}" ]]; then
  collect_error "Template not found: ${WATCHDOG_TEMPLATE}"
  exit 1
fi

sudo sed \
  -e "s|__HOSTNAME__|${HOSTNAME}|g" \
  -e "s|__MONITORING_EMAIL__|${MONITORING_EMAIL}|g" \
  "${WATCHDOG_TEMPLATE}" | sudo tee "${WATCHDOG_DEST}" >/dev/null
sudo chown "${OPERATOR_USERNAME}:staff" "${WATCHDOG_DEST}"
sudo chmod 700 "${WATCHDOG_DEST}"
log "plex-watchdog deployed to ${WATCHDOG_DEST}"

# Deploy plex-watchdog-ctl
CTL_TEMPLATE="${TEMPLATE_DIR}/plex-watchdog-ctl.sh"
if [[ ! -f "${CTL_TEMPLATE}" ]]; then
  collect_error "Template not found: ${CTL_TEMPLATE}"
  exit 1
fi

sudo sed \
  -e "s|__HOSTNAME__|${HOSTNAME}|g" \
  -e "s|__MONITORING_EMAIL__|${MONITORING_EMAIL}|g" \
  "${CTL_TEMPLATE}" | sudo tee "${CTL_DEST}" >/dev/null
sudo chown "${OPERATOR_USERNAME}:staff" "${CTL_DEST}"
sudo chmod 755 "${CTL_DEST}"
log "plex-watchdog-ctl deployed to ${CTL_DEST}"

# ---------------------------------------------------------------------------
# Section 4: Generate initial golden config
# ---------------------------------------------------------------------------

set_section "Golden Config"

GOLDEN_CONF="${WATCHDOG_CONFIG_DIR}/golden.conf"
GOLDEN_TEMPLATE="${TEMPLATE_DIR}/plex-golden.conf.template"
STATE_FILE="${WATCHDOG_CONFIG_DIR}/state.json"

if [[ ! -f "${GOLDEN_TEMPLATE}" ]]; then
  collect_error "Golden config template not found: ${GOLDEN_TEMPLATE}"
  exit 1
fi

# PLEX_TOKEN is still set from Section 2 (redaction deferred to after this section)

# Fetch all current Plex prefs (use header to avoid leaking token in process list)
PREFS_XML=$(curl -sf --max-time 15 -H "X-Plex-Token: ${PLEX_TOKEN}" "http://localhost:32400/:/prefs")
if [[ -z "${PREFS_XML}" ]]; then
  collect_error "Failed to fetch Plex prefs for golden config generation"
  exit 1
fi

# Build a lookup of current plex values: key=value
declare -A PLEX_VALUES
PREF_COUNT=$(echo "${PREFS_XML}" | xmllint --xpath 'count(//Setting)' - 2>/dev/null)
i=1
while [[ ${i} -le ${PREF_COUNT} ]]; do
  pref_id=$(echo "${PREFS_XML}" | xmllint --xpath "string(//Setting[${i}]/@id)" - 2>/dev/null) || true
  pref_val=$(echo "${PREFS_XML}" | xmllint --xpath "string(//Setting[${i}]/@value)" - 2>/dev/null) || true
  if [[ -n "${pref_id}" ]]; then
    PLEX_VALUES["${pref_id}"]="${pref_val}"
  fi
  ((i += 1))
done

log "Fetched ${PREF_COUNT} settings from Plex"

# Process template: replace __VALUE__ placeholders with current Plex values
golden_content=""
while IFS= read -r line; do
  if [[ "${line}" =~ __VALUE__ ]]; then
    # Extract the setting name from commented line "# SettingName: __VALUE__"
    local_key=$(echo "${line}" | sed 's/^[[:space:]]*#[[:space:]]*//' | sed 's/:.*//' | sed 's/[[:space:]]*$//')
    if [[ -n "${local_key}" ]] && [[ -n "${PLEX_VALUES[${local_key}]+x}" ]]; then
      golden_content+="# ${local_key}: ${PLEX_VALUES[${local_key}]}"$'\n'
    else
      # Setting not found in Plex — keep template line with __VALUE__
      golden_content+="${line}"$'\n'
    fi
  else
    golden_content+="${line}"$'\n'
  fi
done <"${GOLDEN_TEMPLATE}"

# Append any Plex settings not in the template to the Internal section
# Collect keys already mentioned in the template
declare -A TEMPLATE_KEYS
while IFS= read -r line; do
  if [[ "${line}" =~ ^[[:space:]]*#?[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*): ]]; then
    tkey=$(echo "${line}" | sed 's/^[[:space:]]*#*[[:space:]]*//' | sed 's/:.*//' | sed 's/[[:space:]]*$//')
    TEMPLATE_KEYS["${tkey}"]=1
  fi
done <"${GOLDEN_TEMPLATE}"

extra_settings=""
extra_count=0
for key in $(echo "${!PLEX_VALUES[@]}" | tr ' ' '\n' | sort); do
  if [[ -z "${TEMPLATE_KEYS[${key}]+x}" ]]; then
    extra_settings+="# ${key}: ${PLEX_VALUES[${key}]}"$'\n'
    ((extra_count += 1))
  fi
done

if [[ ${extra_count} -gt 0 ]]; then
  golden_content+="${extra_settings}"
fi

# Deploy golden config
echo "${golden_content}" | sudo tee "${GOLDEN_CONF}" >/dev/null
sudo chown "${OPERATOR_USERNAME}:staff" "${GOLDEN_CONF}"
sudo chmod 644 "${GOLDEN_CONF}"
log "Golden config generated with ${PREF_COUNT} settings (${extra_count} uncategorized in Internal section)"

# Initialize state file
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "{\"last_poll\": \"${NOW}\", \"last_heartbeat\": \"${NOW}\", \"response_hash\": \"\", \"consecutive_failures\": 0, \"settings\": {}}" \
  | jq '.' | sudo tee "${STATE_FILE}" >/dev/null
sudo chown "${OPERATOR_USERNAME}:staff" "${STATE_FILE}"
sudo chmod 644 "${STATE_FILE}"
log "State file initialized at ${STATE_FILE}"

# Clear token from shell
PLEX_TOKEN="REDACTED"

# ---------------------------------------------------------------------------
# Section 5: Create and load LaunchAgent
# ---------------------------------------------------------------------------

set_section "LaunchAgent"

if [[ ! -d "${LAUNCHAGENT_DIR}" ]]; then
  sudo -iu "${OPERATOR_USERNAME}" mkdir -p "${LAUNCHAGENT_DIR}"
fi

PLIST_FILE="${LAUNCHAGENT_DIR}/com.${HOSTNAME_LOWER}.plex-watchdog.plist"
log "Creating LaunchAgent: ${PLIST_FILE}"

sudo -iu "${OPERATOR_USERNAME}" tee "${PLIST_FILE}" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.plex-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${OPERATOR_HOME}/.local/bin/plex-watchdog</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${OPERATOR_HOME}/.local/state/plex-watchdog.log</string>
  <key>StandardErrorPath</key>
  <string>${OPERATOR_HOME}/.local/state/plex-watchdog.log</string>
</dict>
</plist>
PLIST

sudo chown "${OPERATOR_USERNAME}:staff" "${PLIST_FILE}"
sudo chmod 644 "${PLIST_FILE}"

if sudo plutil -lint "${PLIST_FILE}" >/dev/null 2>&1; then
  log "LaunchAgent created and validated"
else
  collect_error "Invalid plist syntax in ${PLIST_FILE} — launchd will reject this agent"
fi

# ---------------------------------------------------------------------------
# Section 6: Verify deployment
# ---------------------------------------------------------------------------

set_section "Verification"

# Run one poll cycle manually as operator to verify everything works
log "Running initial poll cycle..."

if sudo -iu "${OPERATOR_USERNAME}" bash "${WATCHDOG_DEST}" 2>&1; then
  log "Initial poll cycle completed successfully"
else
  collect_warning "Initial poll cycle exited with non-zero status — check ${OPERATOR_HOME}/.local/state/plex-watchdog.log"
fi

# Verify log output
WATCHDOG_LOG="${OPERATOR_HOME}/.local/state/plex-watchdog.log"
if [[ -f "${WATCHDOG_LOG}" ]]; then
  log "Watchdog log created at ${WATCHDOG_LOG}"
  log "Last log entry: $(sudo tail -1 "${WATCHDOG_LOG}")"
else
  collect_warning "No watchdog log file found after initial run"
fi

# Verify no drift on first run (golden was just generated from current state)
if sudo -iu "${OPERATOR_USERNAME}" bash "${CTL_DEST}" status >/dev/null 2>&1; then
  log "Status check passed — no drift detected (expected for fresh deployment)"
else
  collect_warning "Status check shows drift on fresh deployment — golden config may not match current state"
fi

log ""
log "Plex watchdog setup complete."
log ""
log "  Watchdog:     ${WATCHDOG_DEST} (runs every 5 minutes via LaunchAgent)"
log "  CLI tool:     ${CTL_DEST}"
log "  Golden config: ${GOLDEN_CONF}"
log "  LaunchAgent:  ${PLIST_FILE}"
log ""
log "  To check status:  sudo -iu ${OPERATOR_USERNAME} plex-watchdog-ctl status"
log "  To accept drift:  sudo -iu ${OPERATOR_USERNAME} plex-watchdog-ctl accept"
log "  To revert drift:  sudo -iu ${OPERATOR_USERNAME} plex-watchdog-ctl revert"
log ""
log "  The LaunchAgent will start automatically on operator's next login."
log "  To start it now:  sudo -iu ${OPERATOR_USERNAME} launchctl load ${PLIST_FILE}"
