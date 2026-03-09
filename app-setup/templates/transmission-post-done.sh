#!/usr/bin/env bash
#
# transmission-post-done.sh - Container-side torrent completion trigger
#
# Runs inside the haugene/transmission-openvpn container when a torrent finishes.
# Writes a trigger file to /data/.done/ (NAS-mounted at /data) that the macOS
# transmission-trigger-watcher.sh LaunchAgent picks up to invoke FileBot processing.
#
# Environment variables provided by Transmission:
#   TR_TORRENT_DIR    — parent download directory in container
#                       (e.g. /data/Media/Torrents/pending-move)
#                       NOTE: this is the directory containing the torrent, NOT a path
#                       that includes the torrent name. TR_TORRENT_NAME is the entry
#                       within that directory.
#   TR_TORRENT_NAME   — torrent name (file or directory within TR_TORRENT_DIR)
#   TR_TORRENT_HASH   — torrent hash (unique identifier, used as trigger filename)
#   TR_APP_VERSION    — Transmission version
#
# The trigger file format is KEY=VALUE lines, one per line:
#   TR_TORRENT_NAME=<name>
#   TR_TORRENT_DIR=<dir>
#   TR_TORRENT_HASH=<hash>
#
# Usage: Configured via TRANSMISSION_SCRIPT_TORRENT_DONE_FILENAME in compose.yml.
#   Not intended for manual execution.
#
# Author: Andrew Rich <andrew.rich@gmail.com>

set -euo pipefail

# Validate required environment variables (set by Transmission at runtime).
# The :? form exits with an error message if any variable is unset or empty.
: "${TR_TORRENT_NAME:?TR_TORRENT_NAME must be set by Transmission}"
: "${TR_TORRENT_DIR:?TR_TORRENT_DIR must be set by Transmission}"
: "${TR_TORRENT_HASH:?TR_TORRENT_HASH must be set by Transmission}"

DONE_DIR="/data/.done"
mkdir -p "${DONE_DIR}"

# Write trigger file named by hash to avoid collisions between concurrent completions
TRIGGER_FILE="${DONE_DIR}/${TR_TORRENT_HASH}"

printf 'TR_TORRENT_NAME=%s\nTR_TORRENT_DIR=%s\nTR_TORRENT_HASH=%s\n' \
  "${TR_TORRENT_NAME}" \
  "${TR_TORRENT_DIR}" \
  "${TR_TORRENT_HASH}" \
  >"${TRIGGER_FILE}"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
printf '[%s] [transmission-post-done] Trigger written: %s (%s)\n' \
  "${TIMESTAMP}" \
  "${TR_TORRENT_NAME}" \
  "${TR_TORRENT_HASH}"
