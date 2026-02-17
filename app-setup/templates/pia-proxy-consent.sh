#!/usr/bin/env bash
#
# pia-proxy-consent.sh - PIA Proxy Configuration Consent Auto-Clicker
#
# After reboot, macOS intermittently loses the NE (Network Extension) proxy
# consent signature for PIA's split tunnel. When NETransparentProxyManager
# calls saveToPreferences() and finds "existing signature (null)", macOS
# presents a "Would Like to Add Proxy Configurations" dialog requiring user
# interaction. On a headless server, this blocks split tunnel activation
# indefinitely.
#
# This script watches for that dialog via AppleScript and clicks "Allow"
# within seconds of it appearing. It runs once at login, polls for up to
# 5 minutes (the dialog typically appears within ~15s of boot), then exits.
#
# This is "Stage 1a" — ensuring PIA's split tunnel can activate after reboot.
# Without consent, Stages 1/1.5/2/3b cannot function because split tunnel
# never starts.
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

set -euo pipefail

# Configuration (replaced during deployment)
SERVER_NAME="__SERVER_NAME__"

# Derived configuration
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
POLL_INTERVAL=3 # Check every 3 seconds
MAX_WAIT=300    # Stop polling after 5 minutes

# Logging configuration
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-pia-proxy-consent.log"

mkdir -p "${LOG_DIR}"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [pia-proxy-consent] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
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

  # Try known dialog-hosting processes first (faster than scanning all)
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
# Main
# ---------------------------------------------------------------------------

log "=========================================="
log "PIA proxy consent watcher starting"
log "=========================================="
log "Server: ${SERVER_NAME}"
log "Poll interval: ${POLL_INTERVAL}s, max wait: ${MAX_WAIT}s"

elapsed=0
while ((elapsed < MAX_WAIT)); do
  if click_allow; then
    notify "PIA Proxy Consent" "Auto-clicked Allow for proxy configuration"
    log "Consent granted. Exiting."
    exit 0
  fi
  sleep "${POLL_INTERVAL}"
  ((elapsed += POLL_INTERVAL))
done

log "No dialog seen after ${MAX_WAIT}s. Exiting (normal if consent persisted this boot)."
exit 0
