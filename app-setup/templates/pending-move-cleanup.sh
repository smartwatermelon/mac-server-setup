#!/usr/bin/env bash
#
# pending-move-cleanup.sh - Deferred cleanup of Transmission's pending-move directory
#
# After Transmission processes a torrent, the trigger watcher removes the torrent from
# Transmission WITHOUT deleting local data (to avoid VirtioFS .nfs.* silly-rename issues).
# This script periodically sweeps pending-move/ and removes only directories that are
# confirmed absent from Transmission's active torrent list via RPC.
#
# SAFETY CONSTRAINT: Files may remain in pending-move/ because FileBot failed, the trigger
# was missed, or the content is non-media (ISOs, etc.). Only entries confirmed absent from
# Transmission's torrent list are eligible for deletion. If Transmission RPC is unreachable,
# NO entries are deleted — the script exits cleanly and retries next cycle.
#
# Runs hourly via com.<hostname>.pending-move-cleanup LaunchAgent.
#
# Template placeholders (replaced by setup script at deploy time):
#   __SERVER_NAME__              → server hostname for logging (e.g. TILSIT)
#   __TRANSMISSION_HOST_PORT__   → Transmission RPC port (e.g. 9091)
#   __OPERATOR_HOME__            → operator home directory
#   __NAS_SHARE_NAME__           → NAS share name (e.g. DSMedia)
#
# Author: Andrew Rich <andrew.rich@gmail.com>

set -euo pipefail

SERVER_NAME="__SERVER_NAME__"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"

PENDING_MOVE="${HOME}/.local/mnt/__NAS_SHARE_NAME__/Media/Torrents/pending-move"
TRANSMISSION_RPC_URL="http://localhost:__TRANSMISSION_HOST_PORT__/transmission/rpc"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-pending-move-cleanup.log"
MAX_LOG_SIZE=5242880 # 5MB
# Injected so tests can stub the delete. Default is the real rm.
RM_BIN="${RM_BIN:-rm}"

mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [pending-move-cleanup] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

rotate_log() {
  if [[ -f "${LOG_FILE}" ]]; then
    local size
    size=$(stat -f%z "${LOG_FILE}" 2>/dev/null || echo "0")
    if [[ "${size}" -gt ${MAX_LOG_SIZE} ]]; then
      mv "${LOG_FILE}" "${LOG_FILE}.old"
      log "Log rotated"
    fi
  fi
}

# Fetch active torrent names from Transmission via RPC.
# Prints one torrent name per line. Returns 1 if RPC is unreachable.
get_active_torrent_names() {
  # Get CSRF session token from Transmission's 409 response
  local session_id
  session_id=$(curl -s -D - "${TRANSMISSION_RPC_URL}" 2>/dev/null \
    | awk 'tolower($0) ~ /^x-transmission-session-id:/{gsub(/\r/,""); print $2; exit}')

  if [[ -z "${session_id}" ]]; then
    return 1
  fi

  local response
  response=$(curl -s "${TRANSMISSION_RPC_URL}" \
    -H "X-Transmission-Session-Id: ${session_id}" \
    --data-raw '{"method":"torrent-get","arguments":{"fields":["name"]}}' \
    2>&1)

  if [[ "${response}" != *'"result":"success"'* ]]; then
    return 1
  fi

  # Extract torrent names from JSON response — one per line
  # Uses python3 for reliable JSON parsing (grep/sed can't handle escaped quotes in names)
  printf '%s' "${response}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data.get('arguments', {}).get('torrents', []):
    print(t['name'])
"
}

# True if a dir holds only .nfs.* files: deleted files the VM still has open.
# rm fails on them until they close.
only_nfs_silly_renames() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 1
  # A find error means "not held", so the entry goes to rm as before.
  local nfs other
  nfs=$(find "${dir}" -name '.nfs.*' -print -quit 2>/dev/null) || return 1
  [[ -n "${nfs}" ]] || return 1
  other=$(find "${dir}" -mindepth 1 ! -type d ! -name '.nfs.*' -print -quit 2>/dev/null) || return 1
  [[ -z "${other}" ]]
}

# --- Main ---

rotate_log

# Exit silently if pending-move doesn't exist (NAS not mounted)
if [[ ! -d "${PENDING_MOVE}" ]]; then
  exit 0
fi

# Fetch active torrent names; if RPC unreachable, skip this cycle
active_names_file=$(mktemp)
trap 'rm -f "${active_names_file}"' EXIT

if ! get_active_torrent_names >"${active_names_file}"; then
  log "WARNING: Cannot reach Transmission RPC — skipping cleanup cycle"
  exit 0
fi

cleaned=0
skipped=0
held=0
failed=0

while IFS= read -r -d '' entry; do
  basename=$(basename "${entry}")

  # Skip dotfiles (.DS_Store, ._, etc.)
  if [[ "${basename}" == .* ]]; then
    continue
  fi

  # If entry matches an active torrent name, leave it alone.
  # With the incomplete directory disabled and rename-partial-files on,
  # Transmission writes a single-file torrent as "<name>.part" until it
  # completes, so an in-progress download never matches its torrent name
  # verbatim. Compare with the suffix stripped, or the sweep deletes a
  # download that is still being written (issue: Seven Psychopaths, 2026-09-05).
  if grep -qxF "${basename%.part}" "${active_names_file}"; then
    skipped=$((skipped + 1))
    continue
  fi

  # Not tracked by Transmission, but the only thing left is a file another
  # process still holds open. Nothing here can be removed yet.
  if only_nfs_silly_renames "${entry}"; then
    held=$((held + 1))
    continue
  fi

  # Not tracked by Transmission, so safe to remove. Under set -e a bare
  # failed rm would end the sweep and skip every later entry.
  log "Removing orphaned entry: ${basename}"
  if "${RM_BIN}" -rf "${entry}"; then
    cleaned=$((cleaned + 1))
  elif only_nfs_silly_renames "${entry}"; then
    log "Left in place: ${basename} (only .nfs.* files remain; another process still has them open)"
    held=$((held + 1))
  else
    log "ERROR: could not remove ${basename}"
    failed=$((failed + 1))
  fi
done < <(find "${PENDING_MOVE}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)

# Held entries alone do not produce a log line, so a directory that stays
# held for days does not write the same line every hour.
if [[ "${cleaned}" -gt 0 ]] || [[ "${skipped}" -gt 0 ]] || [[ "${failed}" -gt 0 ]]; then
  log "Cleanup complete: ${cleaned} removed, ${skipped} still tracked by Transmission, ${held} held open (.nfs.* only), ${failed} failed"
fi

[[ "${failed}" -eq 0 ]]
