#!/usr/bin/env bash
#
# transmission-trigger-watcher.sh - macOS trigger file watcher for containerized Transmission
#
# Polls ~/containers/transmission/config/triggers/ for trigger files written by the
# transmission-post-done.sh script running inside the haugene container.
# On finding a trigger file, maps the container-internal /data path to the macOS NAS
# mount path and invokes the existing transmission-done with the correct env vars.
# Triggers are written to a host-local path (not the NAS) to avoid macOS TCC/sandbox
# restrictions that prevent LaunchAgents from reading SMB-mounted directories.
#
# Runs as a persistent daemon via com.<hostname>.transmission-trigger-watcher LaunchAgent.
# Replaces the native Transmission.app "Done Script" mechanism used before containerization.
#
# Dead-letter handling: if the done script fails, a .retry.<n> sentinel file is created.
# After MAX_RETRIES failures the trigger file is renamed to .dead and skipped permanently.
# Dead files accumulate in the .done directory for manual inspection.
#
# Template placeholders (replaced by podman-transmission-setup.sh at deploy time):
#   __SERVER_NAME__ → server hostname for logging (e.g. TILSIT)
#
# Author: Andrew Rich <andrew.rich@gmail.com>

set -euo pipefail

SERVER_NAME="__SERVER_NAME__"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"

DONE_DIR="${HOME}/containers/transmission/config/triggers"
DONE_SCRIPT="${HOME}/.local/bin/transmission-done"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-transmission-trigger-watcher.log"
MAX_LOG_SIZE=5242880 # 5MB
POLL_INTERVAL=60
MAX_RETRIES=5 # Trigger files retained up to this many poll cycles on failure

# Container-to-macOS path prefix mapping
# Container mounts NAS at /data; macOS mounts it at ~/.local/mnt/DSMedia
CONTAINER_DATA_PREFIX="/data"
MACOS_NAS_PREFIX="${HOME}/.local/mnt/DSMedia"

mkdir -p "$(dirname "${LOG_FILE}")"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [trigger-watcher] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
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

# Map a container-internal /data path to the macOS NAS mount path
map_container_path() {
  local container_path="$1"
  echo "${MACOS_NAS_PREFIX}${container_path#"${CONTAINER_DATA_PREFIX}"}"
}

process_trigger() {
  local trigger_file="$1"
  local name dir hash

  # Parse trigger file (KEY=VALUE lines).
  # grep exits 1 on no match; || true prevents set -e from killing the script
  # when a field is absent (malformed file handled by the empty-check below).
  name=$(grep '^TR_TORRENT_NAME=' "${trigger_file}" | cut -d= -f2- || true)
  dir=$(grep '^TR_TORRENT_DIR=' "${trigger_file}" | cut -d= -f2- || true)
  hash=$(grep '^TR_TORRENT_HASH=' "${trigger_file}" | cut -d= -f2- || true)

  if [[ -z "${name}" ]] || [[ -z "${dir}" ]] || [[ -z "${hash}" ]]; then
    log "ERROR: Malformed trigger file ${trigger_file} — removing"
    rm -f "${trigger_file}"
    return 1
  fi

  # Check retry count (each failed attempt creates a .retry.<n> sentinel file)
  local retry_count=0
  retry_count=$(find "${DONE_DIR}" \
    -name "${hash}.retry.*" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${retry_count}" -ge "${MAX_RETRIES}" ]]; then
    log "ERROR: ${hash} failed ${MAX_RETRIES} times — moving to .dead for manual inspection"
    mv "${trigger_file}" "${DONE_DIR}/${hash}.dead"
    find "${DONE_DIR}" -name "${hash}.retry.*" -delete 2>/dev/null || true
    return 1
  fi

  # Map container path to macOS NAS path
  local macos_dir
  macos_dir=$(map_container_path "${dir}")

  log "Processing: ${name} (hash: ${hash})"
  log "  Container path: ${dir}"
  log "  macOS path:     ${macos_dir}"

  if [[ ! -d "${macos_dir}" ]]; then
    log "WARNING: macOS path does not exist: ${macos_dir} — NAS may not be mounted"
    return 1
  fi

  if [[ ! -x "${DONE_SCRIPT}" ]]; then
    log "ERROR: Done script not found or not executable: ${DONE_SCRIPT}"
    return 1
  fi

  # Invoke the existing macOS done script with Transmission's standard env vars
  if TR_TORRENT_NAME="${name}" \
    TR_TORRENT_DIR="${macos_dir}" \
    TR_TORRENT_HASH="${hash}" \
    "${DONE_SCRIPT}"; then
    log "Done script succeeded for: ${name}"
    rm -f "${trigger_file}"
    find "${DONE_DIR}" -name "${hash}.retry.*" -delete 2>/dev/null || true
  else
    local next_retry=$((retry_count + 1))
    log "ERROR: Done script failed for: ${name} (attempt ${next_retry}/${MAX_RETRIES})"
    touch "${DONE_DIR}/${hash}.retry.${next_retry}"
    return 1
  fi
}

trap 'log "Trigger watcher stopping (signal received)"; exit 0' INT TERM

log "=========================================="
log "Transmission trigger watcher starting"
log "=========================================="
log "Server:        ${SERVER_NAME}"
log "Done dir:      ${DONE_DIR}"
log "Done script:   ${DONE_SCRIPT}"
log "Poll interval: ${POLL_INTERVAL}s"
log "Max retries:   ${MAX_RETRIES}"

loop_count=0
while true; do
  ((loop_count += 1))

  # Rotate log approximately once per hour (60 * 60s = 3600s)
  if [[ $((loop_count % 60)) -eq 0 ]]; then
    rotate_log
  fi

  if [[ -d "${DONE_DIR}" ]]; then
    # Process trigger files; skip .retry.* sentinels and .dead files
    while IFS= read -r -d '' trigger_file; do
      process_trigger "${trigger_file}" || true
    done < <(find "${DONE_DIR}" -maxdepth 1 -type f \
      ! -name '*.retry.*' ! -name '*.dead' -print0 2>/dev/null || true)
  fi

  sleep "${POLL_INTERVAL}"
done
