#!/usr/bin/env bash
#
# transmission-done.sh - Transmission completion script
# Called when a torrent finishes downloading
#
# Environment variables provided by Transmission:
# TR_APP_VERSION, TR_TIME_LOCALTIME, TR_TORRENT_DIR, TR_TORRENT_HASH,
# TR_TORRENT_ID, TR_TORRENT_NAME

# Log completion
LOG_FILE="${HOME}/.local/state/transmission-completion.log"
mkdir -p "$(dirname "${LOG_FILE}")"
timestamp=$(date '+%Y-%m-%d %H:%M:%S')
echo "${timestamp} - Torrent completed: ${TR_TORRENT_NAME:-unknown}" >>"${LOG_FILE}"

# Future: FileBot integration will be added here
# filebot -rename "${TR_TORRENT_DIR}/${TR_TORRENT_NAME}" --output /path/to/media/library

exit 0
