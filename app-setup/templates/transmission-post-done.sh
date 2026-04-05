#!/usr/bin/env bash
#
# transmission-post-done.sh - Container-side torrent completion trigger
#
# Runs inside the haugene/transmission-openvpn container when a torrent finishes.
# Writes a trigger file to /config/triggers/ (host-local via bind mount) that the
# macOS transmission-trigger-watcher.sh LaunchAgent picks up to invoke FileBot.
# Uses /config (local disk) instead of /data (NAS/SMB) so the LaunchAgent can
# read triggers without Full Disk Access to network mounts.
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
#   TR_TORRENT_FILES=<pipe-separated list of file paths relative to TR_TORRENT_DIR>
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

DONE_DIR="/config/triggers"
mkdir -p "${DONE_DIR}"

# Write trigger file named by hash to avoid collisions between concurrent completions
TRIGGER_FILE="${DONE_DIR}/${TR_TORRENT_HASH}"

# List all files in the torrent directory (relative paths with torrent name prefix).
# The macOS host cannot opendir() NFS-mounted directories from LaunchAgent processes,
# so including the file list here allows the host to access files by direct path.
TORRENT_PATH="${TR_TORRENT_DIR}/${TR_TORRENT_NAME}"
TORRENT_FILES=""
if [[ -d "${TORRENT_PATH}" ]]; then
  # Directory torrent: list all files, strip the absolute prefix to get paths
  # relative to TR_TORRENT_DIR, then join with pipes for single-line storage
  # in the KEY=VALUE trigger format. Pipe delimiter is chosen because it's
  # illegal in most filesystems (NTFS, HFS+) though technically allowed on ext4.
  # find(1) works here — this runs inside the container, not on macOS host.
  TORRENT_FILES=$(find "${TORRENT_PATH}" -type f 2>/dev/null \
    | while IFS= read -r f; do echo "${f#"${TR_TORRENT_DIR}"/}"; done \
    | tr '\n' '|' \
    | sed 's/|$//')
elif [[ -f "${TORRENT_PATH}" ]]; then
  # Single-file torrent
  TORRENT_FILES="${TR_TORRENT_NAME}"
fi

printf 'TR_TORRENT_NAME=%s\nTR_TORRENT_DIR=%s\nTR_TORRENT_HASH=%s\nTR_TORRENT_FILES=%s\n' \
  "${TR_TORRENT_NAME}" \
  "${TR_TORRENT_DIR}" \
  "${TR_TORRENT_HASH}" \
  "${TORRENT_FILES}" \
  >"${TRIGGER_FILE}"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
printf '[%s] [transmission-post-done] Trigger written: %s (%s)\n' \
  "${TIMESTAMP}" \
  "${TR_TORRENT_NAME}" \
  "${TR_TORRENT_HASH}"
