#!/usr/bin/env bash
#
# pia-split-tunnel-monitor.sh - PIA Split Tunnel Configuration Watchdog
#
# Monitors PIA's settings.json for split tunnel configuration drift and
# auto-restores from a saved reference. PIA frequently "forgets" its split
# tunnel rules; with the Stage 1 inversion architecture (Bypass VPN for
# Plex/Backblaze/Safari, everything else through VPN), forgetting means
# all traffic goes through VPN — including Plex, which is unusable through
# a multi-hop overseas VPN connection.
#
# This is "Stage 1.5" — enforcing the PIA config that Stage 1 depends on.
# The vpn-monitor.sh (Stage 2) handles VPN drops but not PIA config drift.
#
# Architecture:
#   - READ:    /Library/Preferences/.../settings.json (world-readable)
#   - COMPARE: against reference at ~/.local/etc/pia-split-tunnel-reference.json
#   - FIX:     piactl -u applysettings + disconnect/connect cycle
#   - VERIFY:  re-read settings, confirm fix took effect
#   - NOTIFY:  terminal-notifier
#
# Template placeholders (replaced during deployment):
#   - __SERVER_NAME__: Server hostname for logging and preferences
#
# Usage: Launched automatically by com.<hostname>.pia-monitor LaunchAgent
#   Not intended for manual execution.
#   Pass --save-reference to capture current PIA config as the new reference.
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-13

set -euo pipefail

# Configuration (replaced during deployment)
SERVER_NAME="__SERVER_NAME__"

# Derived configuration
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
POLL_INTERVAL=60

# Paths
PIA_SETTINGS="/Library/Preferences/com.privateinternetaccess.vpn/settings.json"
REFERENCE_DIR="${HOME}/.local/etc"
REFERENCE_FILE="${REFERENCE_DIR}/pia-split-tunnel-reference.json"
PAUSE_FILE="${REFERENCE_DIR}/pia-monitor-paused"
PIACTL="/usr/local/bin/piactl"

# Logging configuration
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-pia-monitor.log"
MAX_LOG_SIZE=5242880 # 5MB

# State tracking
CONSECUTIVE_FAILURES=0
MAX_FAILURES=3
BACKOFF_UNTIL=0

# Ensure directories exist
mkdir -p "${LOG_DIR}" "${REFERENCE_DIR}"

# ---------------------------------------------------------------------------
# Logging & Notification
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [pia-monitor] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

rotate_log() {
  if [[ -f "${LOG_FILE}" ]]; then
    local size
    size=$(stat -f%z "${LOG_FILE}" 2>/dev/null || echo "0")
    if [[ "${size}" -gt ${MAX_LOG_SIZE} ]]; then
      mv "${LOG_FILE}" "${LOG_FILE}.old"
      log "Log rotated (previous log exceeded ${MAX_LOG_SIZE} bytes)"
    fi
  fi
}

notify() {
  local title="$1"
  local message="$2"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier \
      -title "${title}" \
      -message "${message}" \
      -group "pia-monitor" \
      -sender "com.privateinternetaccess.vpn" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# JSON Extraction & Comparison
# ---------------------------------------------------------------------------

# Extract monitored fields from PIA settings.json
# Returns a normalized JSON object with only the fields we care about.
# Uses python3 (guaranteed on macOS; jq is not installed by default).
extract_monitored_fields() {
  local settings_file="$1"
  python3 - "${settings_file}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    monitored = {
        'splitTunnelEnabled': s.get('splitTunnelEnabled', False),
        'splitTunnelRules': s.get('splitTunnelRules', []),
        'killswitch': s.get('killswitch', ''),
        'bypassSubnets': s.get('bypassSubnets', [])
    }
    print(json.dumps(monitored, sort_keys=True, indent=2))
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Compare two JSON strings for equality (order-independent for arrays of objects)
configs_match() {
  local current="$1"
  local reference="$2"
  python3 - "${current}" "${reference}" <<'PYEOF'
import json, sys

def normalize(obj):
    if isinstance(obj, dict):
        return {k: normalize(v) for k, v in sorted(obj.items())}
    if isinstance(obj, list):
        normalized = [normalize(item) for item in obj]
        # Sort lists of dicts by their JSON representation for stable comparison
        try:
            return sorted(normalized, key=lambda x: json.dumps(x, sort_keys=True))
        except TypeError:
            return normalized
    return obj

try:
    current = json.loads(sys.argv[1])
    reference = json.loads(sys.argv[2])
    if normalize(current) == normalize(reference):
        sys.exit(0)
    else:
        sys.exit(1)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(2)
PYEOF
}

# ---------------------------------------------------------------------------
# Reference Management
# ---------------------------------------------------------------------------

# Save current PIA config as the reference
save_reference() {
  if [[ ! -f "${PIA_SETTINGS}" ]]; then
    log "ERROR: PIA settings file not found at ${PIA_SETTINGS}"
    return 1
  fi

  local extracted
  if ! extracted=$(extract_monitored_fields "${PIA_SETTINGS}") || [[ -z "${extracted}" ]]; then
    log "ERROR: Failed to extract monitored fields from PIA settings"
    return 1
  fi

  echo "${extracted}" >"${REFERENCE_FILE}"
  log "Reference config saved to ${REFERENCE_FILE}"
  log "Contents:"
  while IFS= read -r line; do
    log "  ${line}"
  done <<<"${extracted}"

  # Remove pause file if present — saving reference means we're done changing
  if [[ -f "${PAUSE_FILE}" ]]; then
    rm -f "${PAUSE_FILE}"
    log "Pause file removed — monitoring resumed with new reference"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Fix & Verify
# ---------------------------------------------------------------------------

# Apply the reference config to PIA using piactl -u applysettings
apply_fix() {
  if [[ ! -x "${PIACTL}" ]]; then
    log "ERROR: piactl not found at ${PIACTL} — cannot auto-fix (detect-only mode)"
    return 1
  fi

  local reference_json
  reference_json=$(cat "${REFERENCE_FILE}")

  log "Applying reference config via piactl -u applysettings..."
  if "${PIACTL}" -u applysettings "${reference_json}" 2>&1; then
    log "applysettings command succeeded"
  else
    log "ERROR: applysettings command failed"
    return 1
  fi

  # Reconnect to force PIA to apply the new settings
  log "Reconnecting PIA to apply settings..."
  "${PIACTL}" disconnect 2>/dev/null || true
  sleep 3
  "${PIACTL}" connect 2>/dev/null || true
  sleep 10

  return 0
}

# Verify that the fix took effect by re-reading settings
verify_fix() {
  local current
  if ! current=$(extract_monitored_fields "${PIA_SETTINGS}") || [[ -z "${current}" ]]; then
    log "ERROR: Failed to read settings after fix attempt"
    return 1
  fi

  local reference
  if ! reference=$(cat "${REFERENCE_FILE}" 2>/dev/null) || [[ -z "${reference}" ]]; then
    log "ERROR: Reference file not found or empty during verification"
    return 1
  fi

  if configs_match "${current}" "${reference}"; then
    log "Verification passed — settings match reference"
    return 0
  else
    log "Verification FAILED — settings still do not match reference"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Drift Detection & Recovery
# ---------------------------------------------------------------------------

check_and_fix() {
  # Check backoff
  local now
  now=$(date +%s)
  if [[ "${now}" -lt "${BACKOFF_UNTIL}" ]]; then
    return 0
  fi

  # Check PIA is installed
  if [[ ! -f "${PIA_SETTINGS}" ]]; then
    log "WARNING: PIA settings file not found — PIA may not be installed or running"
    return 0
  fi

  # Extract current config
  local current
  if ! current=$(extract_monitored_fields "${PIA_SETTINGS}") || [[ -z "${current}" ]]; then
    log "WARNING: Failed to extract current PIA settings — skipping check"
    return 0
  fi

  # Compare against reference (atomic read — no TOCTOU race with -f check)
  local reference
  if ! reference=$(cat "${REFERENCE_FILE}" 2>/dev/null) || [[ -z "${reference}" ]]; then
    log "ERROR: Reference file missing or empty — cannot check for drift"
    return 1
  fi

  # Pause-file check: when paused, detect drift but skip auto-restore.
  # This allows intentional PIA config changes without the monitor reverting them.
  # Use --save-reference to save new config and unpause in one step.
  if [[ -f "${PAUSE_FILE}" ]]; then
    if ! configs_match "${current}" "${reference}"; then
      log "PAUSED — drift detected but auto-restore disabled (${PAUSE_FILE} exists)"
      log "  Run with --save-reference to save current config and resume monitoring"
    fi
    return 0
  fi

  if configs_match "${current}" "${reference}"; then
    # Config matches — reset failure counter
    if [[ "${CONSECUTIVE_FAILURES}" -gt 0 ]]; then
      log "Config matches reference again (was drifted for ${CONSECUTIVE_FAILURES} cycle(s))"
      CONSECUTIVE_FAILURES=0
    fi
    return 0
  fi

  # Config has drifted!
  log "DRIFT DETECTED — PIA split tunnel config does not match reference"
  log "Current config:"
  while IFS= read -r line; do
    log "  ${line}"
  done <<<"${current}"

  notify "PIA Config Drift" "Split tunnel config changed — attempting auto-restore"

  # Attempt fix
  if apply_fix; then
    if verify_fix; then
      log "Auto-restore SUCCEEDED"
      notify "PIA Config Restored" "Split tunnel configuration restored from reference"
      CONSECUTIVE_FAILURES=0
      return 0
    fi
  fi

  # Fix failed
  ((CONSECUTIVE_FAILURES += 1))
  log "Fix attempt ${CONSECUTIVE_FAILURES}/${MAX_FAILURES} failed"

  if [[ "${CONSECUTIVE_FAILURES}" -ge "${MAX_FAILURES}" ]]; then
    BACKOFF_UNTIL=$((now + 300))
    local backoff_time
    backoff_time=$(date -r "${BACKOFF_UNTIL}" '+%H:%M:%S') || true
    log "Max failures reached — backing off for 5 minutes (until ${backoff_time})"
    notify "PIA Monitor" "Auto-restore failed ${MAX_FAILURES} times — backing off 5 min"
    CONSECUTIVE_FAILURES=0
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  # Handle --save-reference flag
  if [[ "${1:-}" == "--save-reference" ]]; then
    log "Saving current PIA config as reference..."
    save_reference
    exit $?
  fi

  # Verify reference file exists
  if [[ ! -f "${REFERENCE_FILE}" ]]; then
    log "ERROR: Reference file not found at ${REFERENCE_FILE}"
    log "Run with --save-reference first, or deploy via transmission-setup.sh"
    exit 1
  fi

  log "=========================================="
  log "PIA split tunnel monitor starting"
  log "=========================================="
  log "Server: ${SERVER_NAME}"
  log "Poll interval: ${POLL_INTERVAL}s"
  log "PIA settings: ${PIA_SETTINGS}"
  log "Reference file: ${REFERENCE_FILE}"

  # Log current reference
  log "Reference config:"
  while IFS= read -r line; do
    log "  ${line}"
  done <"${REFERENCE_FILE}"

  # Log pause state
  if [[ -f "${PAUSE_FILE}" ]]; then
    log "WARNING: Pause file present — auto-restore disabled until --save-reference or manual removal"
  fi

  # Initial check (non-fatal — errors are logged, not terminal)
  check_and_fix || true

  # Main polling loop
  local loop_count=0
  while true; do
    sleep "${POLL_INTERVAL}"

    # Rotate log periodically (~every hour at 60s intervals)
    ((loop_count += 1))
    if [[ $((loop_count % 60)) -eq 0 ]]; then
      rotate_log
    fi

    check_and_fix || true
  done
}

# Signal handling for graceful shutdown
trap 'log "PIA monitor stopping (signal received)"; exit 0' INT TERM

# Entry point
main "$@"
