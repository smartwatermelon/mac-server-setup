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

# Remove the completed torrent from Transmission (keep data on disk).
# This releases file handles held by Transmission/VirtioFS so the host-side
# post-done script can freely rename and move files on the NFS mount.
# Without this, VirtioFS holds FDs → NFS silly-renames block file operations.
RPC_URL="http://localhost:9091/transmission/rpc"
RPC_SESSION=$(curl -sf -o /dev/null -D - "${RPC_URL}" 2>/dev/null \
  | sed -n 's/.*X-Transmission-Session-Id: *\([^ ]*\).*/\1/p' | tr -d '\r\n')

if [[ -n "${RPC_SESSION}" ]]; then
  # Look up torrent ID by hash, then remove (delete-local-data=false keeps files)
  TORRENT_ID=$(curl -sf \
    -H "X-Transmission-Session-Id: ${RPC_SESSION}" \
    -d "{\"method\":\"torrent-get\",\"arguments\":{\"ids\":[\"${TR_TORRENT_HASH}\"],\"fields\":[\"id\"]}}" \
    "${RPC_URL}" 2>/dev/null \
    | sed -n 's/.*"id":\([0-9]*\).*/\1/p')

  if [[ -n "${TORRENT_ID}" ]]; then
    curl -sf \
      -H "X-Transmission-Session-Id: ${RPC_SESSION}" \
      -d "{\"method\":\"torrent-remove\",\"arguments\":{\"ids\":[${TORRENT_ID}],\"delete-local-data\":false}}" \
      "${RPC_URL}" >/dev/null 2>&1 || true

    # Brief pause for Transmission to close file handles and VirtioFS to release FDs
    sleep 3
  fi
fi

# Write trigger file named by hash to avoid collisions between concurrent completions
TRIGGER_FILE="${DONE_DIR}/${TR_TORRENT_HASH}"

printf 'TR_TORRENT_NAME=%s\nTR_TORRENT_DIR=%s\nTR_TORRENT_HASH=%s\n' \
  "${TR_TORRENT_NAME}" \
  "${TR_TORRENT_DIR}" \
  "${TR_TORRENT_HASH}" \
  >"${TRIGGER_FILE}"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
printf '[%s] [transmission-post-done] Trigger written: %s (%s) [torrent removed from Transmission]\n' \
  "${TIMESTAMP}" \
  "${TR_TORRENT_NAME}" \
  "${TR_TORRENT_HASH}"
