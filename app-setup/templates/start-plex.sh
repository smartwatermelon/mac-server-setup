#!/usr/bin/env bash
#
# start-plex.sh - Simple Plex Media Server launcher
#
# This script simply launches Plex Media Server. Library path updates
# are handled during the migration process in plex-setup.sh.
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2025-08-21

set -euo pipefail

# Configuration
PLEX_APP_PATH="/Applications/Plex Media Server.app"

# Logging function
log() {
  local timestamp
  timestamp=$(date '+%H:%M:%S') || true
  echo "[${timestamp}] $*"
}

# Main execution
main() {
  log "🚀 Starting Plex Media Server..."

  if [[ -d "${PLEX_APP_PATH}" ]]; then
    open "${PLEX_APP_PATH}"
    log "✅ Plex Media Server launched"
  else
    log "❌ Plex Media Server not found at: ${PLEX_APP_PATH}"
    exit 1
  fi
}

# Execute main function
main "$@"
