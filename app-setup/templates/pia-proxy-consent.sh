#!/usr/bin/env bash
#
# pia-proxy-consent.sh - PIA Proxy Configuration Consent Auto-Clicker (Daemon)
#
# After reboot, macOS intermittently loses the NE (Network Extension) proxy
# consent signature for PIA's split tunnel. When NETransparentProxyManager
# calls saveToPreferences() and finds "existing signature (null)", macOS
# presents a "Would Like to Add Proxy Configurations" dialog requiring user
# interaction. On a headless server, this blocks split tunnel activation
# indefinitely.
#
# This script runs as a persistent daemon (KeepAlive LaunchAgent) that checks
# every 10 seconds for the consent dialog and clicks "Allow" when found. The
# daemon pattern avoids the launchd ThrottleInterval escalation that occurs
# when StartInterval jobs exit quickly: repeated rapid exits cause launchd to
# back off well beyond the configured interval, causing multi-hour gaps.
#
# This is "Stage 1a" — ensuring PIA's split tunnel can activate after reboot
# or after any mid-session consent reset. Without consent, Stages 1/1.5/2/3b
# cannot function because split tunnel never starts.
#
# Prerequisites:
#   Accessibility permission for /bin/bash (or the shell running this script).
#   Grant at: System Settings > Privacy & Security > Accessibility
#
# Template placeholders (replaced during deployment):
#   - __SERVER_NAME__: Server hostname for logging
#
# Usage: Launched automatically by com.<hostname>.pia-proxy-consent LaunchAgent
#   Not intended for manual execution.
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-17
# Updated: 2026-02-27 — converted to daemon pattern to fix launchd throttle
#                        escalation that caused multi-hour gaps between checks

set -euo pipefail

# Configuration (replaced during deployment)
SERVER_NAME="__SERVER_NAME__"

# Derived configuration
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
POLL_INTERVAL=10    # Check every 10 seconds
POST_CLICK_SLEEP=60 # After clicking, back off 60s before resuming

# Logging configuration
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-pia-proxy-consent.log"
MAX_LOG_SIZE=5242880 # 5MB

mkdir -p "${LOG_DIR}"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [pia-proxy-consent] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
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

# Send desktop notification via terminal-notifier (if available)
notify() {
  local title="$1"
  local message="$2"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier \
      -title "${title}" \
      -message "${message}" \
      -group "pia-proxy-consent" 2>/dev/null || true
  fi
}

# Try to find and click "Allow" on the PIA proxy consent dialog.
# The dialog can be presented by different macOS processes depending on version.
# Returns 0 if clicked, 1 if not found.
click_allow() {
  local result="not_found"

  # Try known dialog-hosting processes first (faster than scanning all).
  # UserNotificationCenter is the most common presenter on macOS 15/16.
  local candidates=(
    "UserNotificationCenter"
    "SystemUIServer"
    "SecurityAgent"
  )

  for proc in "${candidates[@]}"; do
    result=$(osascript -e "
            tell application \"System Events\"
                if exists (process \"${proc}\") then
                    tell process \"${proc}\"
                        repeat with w in windows
                            try
                                set windowText to value of static text of w
                                repeat with t in windowText
                                    if t contains \"Proxy Configurations\" or t contains \"PIA Split Tunnel\" then
                                        click button \"Allow\" of w
                                        return \"clicked:${proc}\"
                                    end if
                                end repeat
                            end try
                        end repeat
                    end tell
                end if
            end tell
            return \"not_found\"
        " 2>/dev/null) || true

    if [[ "${result}" != "not_found" ]]; then
      break
    fi
  done

  # Fallback: scan all processes for any window mentioning PIA/Proxy with an Allow button
  if [[ "${result}" == "not_found" ]]; then
    result=$(osascript -e "
            tell application \"System Events\"
                repeat with proc in processes
                    try
                        tell proc
                            repeat with w in windows
                                try
                                    set windowText to value of static text of w
                                    repeat with t in windowText
                                        if (t contains \"Proxy\" or t contains \"PIA\") and exists button \"Allow\" of w then
                                            click button \"Allow\" of w
                                            return \"clicked:\" & name of proc
                                        end if
                                    end repeat
                                end try
                            end repeat
                        end tell
                    end try
                end repeat
            end tell
            return \"not_found\"
        " 2>/dev/null) || true
  fi

  if [[ "${result}" == clicked:* ]]; then
    local process_name="${result#clicked:}"
    log "Clicked Allow on PIA proxy consent dialog (process: ${process_name})"
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Main daemon loop
# ---------------------------------------------------------------------------

trap 'log "PIA proxy consent watcher stopping (signal received)"; exit 0' INT TERM

log "=========================================="
log "PIA proxy consent watcher starting (daemon)"
log "=========================================="
log "Server: ${SERVER_NAME}"
log "Poll interval: ${POLL_INTERVAL}s"

# Brief initial delay to let the desktop session fully initialize before
# the first AppleScript attempt.
sleep 15

loop_count=0
while true; do
  ((loop_count += 1))

  # Rotate log every ~hour (360 * 10s = 3600s)
  if [[ $((loop_count % 360)) -eq 0 ]]; then
    rotate_log
  fi

  if click_allow; then
    notify "PIA Proxy Consent" "Auto-clicked Allow for proxy configuration"
    log "Consent granted. Backing off ${POST_CLICK_SLEEP}s before resuming."
    sleep "${POST_CLICK_SLEEP}"
  else
    sleep "${POLL_INTERVAL}"
  fi
done
