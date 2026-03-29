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
#
# Author: Andrew Rich <andrew.rich@gmail.com>

set -euo pipefail

SERVER_NAME="__SERVER_NAME__"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"

PENDING_MOVE="${HOME}/.local/mnt/DSMedia/Media/Torrents/pending-move"
TRANSMISSION_RPC_URL="http://localhost:__TRANSMISSION_HOST_PORT__/transmission/rpc"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-pending-move-cleanup.log"
MAX_LOG_SIZE=5242880 # 5MB

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
  # Matches "name":"<value>" pairs; handles escaped quotes in names
  echo "${response}" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"$//'
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

while IFS= read -r -d '' entry; do
  basename=$(basename "${entry}")

  # Skip dotfiles (.DS_Store, ._, etc.)
  if [[ "${basename}" == .* ]]; then
    continue
  fi

  # If entry matches an active torrent name, leave it alone
  if grep -qxF "${basename}" "${active_names_file}"; then
    skipped=$((skipped + 1))
    continue
  fi

  # Entry is not tracked by Transmission — safe to remove
  log "Removing orphaned entry: ${basename}"
  rm -rf "${entry}"
  cleaned=$((cleaned + 1))
done < <(find "${PENDING_MOVE}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)

if [[ "${cleaned}" -gt 0 ]] || [[ "${skipped}" -gt 0 ]]; then
  log "Cleanup complete: ${cleaned} removed, ${skipped} still tracked by Transmission"
fi
