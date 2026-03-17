#!/usr/bin/env bash

# mount-nas-media.sh - User-specific NFS mount script for NAS media access
# This script is designed to be called by a per-user LaunchAgent
# to provide persistent NFS mounting for individual users.

set -euo pipefail

# Load Homebrew paths from system-wide configuration (LaunchAgent doesn't inherit PATH)
if [[ -f "/etc/paths.d/homebrew" ]]; then
  HOMEBREW_PATHS=$(cat /etc/paths.d/homebrew)
  export PATH="${HOMEBREW_PATHS}:${PATH}"
fi

# Configuration - these will be set during installation
NAS_HOSTNAME="__NAS_HOSTNAME__"
NAS_SHARE_NAME="__NAS_SHARE_NAME__"
NAS_VOLUME="__NAS_VOLUME__"
PLEX_MEDIA_MOUNT="${HOME}/.local/mnt/__NAS_SHARE_NAME__"
SERVER_NAME="__SERVER_NAME__"
WHOAMI="$(whoami)"
IDG="$(id -gn)"
IDU="$(id -un)"

# Logging configuration
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-mount.log"

# Ensure directories exist
mkdir -p "${HOME}/.local/state"
mkdir -p "${HOME}/.local/mnt"

# Ensure log file exists with proper permissions
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"
truncate -s 0 "${LOG_FILE}" || true

# Logging function
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${timestamp} [mount-nas-media] $*" | tee -a "${LOG_FILE}"
}

# Wait for network connectivity
wait_for_network() {
  local max_attempts=30
  local attempt=1

  log "Waiting for network connectivity to ${NAS_HOSTNAME}..."

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if ping -c 1 -W 5000 "${NAS_HOSTNAME}" >/dev/null 2>&1; then
      log "✅ Network connectivity to ${NAS_HOSTNAME} established (attempt ${attempt})"
      return 0
    fi

    log "   Attempt ${attempt}/${max_attempts}: No connectivity to ${NAS_HOSTNAME}, waiting 5 seconds..."
    sleep 5
    ((attempt += 1))
  done

  log "❌ Failed to establish network connectivity to ${NAS_HOSTNAME} after ${max_attempts} attempts"
  return 1
}

test_mount() {
  # Test basic mount verification using NFS mount type
  if ! mount -t nfs | grep -q "${PLEX_MEDIA_MOUNT}"; then
    log "⚠️  Mount not visible in system mount table for NFS mount"
    return 1
  fi
  log "✅ Mount verification successful (active NFS mount found)"
  return 0
}

# Main execution - idempotent mounting process
main() {
  log "Starting idempotent NAS media mount process"
  log "Target: ${PLEX_MEDIA_MOUNT}"
  log "Running as: ${WHOAMI} (${IDU}:${IDG})"

  local nfs_source="${NAS_HOSTNAME}:/${NAS_VOLUME}/${NAS_SHARE_NAME}"
  log "Source: ${nfs_source}"

  # Wait for network connectivity first
  if ! wait_for_network; then
    log "❌ Cannot proceed without network connectivity"
    exit 1
  fi

  # Step 0: Check for existing mount; return 0 if true
  log "Step 0: Check for existing mount..."
  if test_mount; then
    return 0
  fi

  # Step 1: Unmount existing mount (ignore failures)
  log "Step 1: Unmounting any existing mount..."
  sudo /sbin/umount "${PLEX_MEDIA_MOUNT}" 2>/dev/null || true
  log "✅ Unmount completed (or was not mounted)"

  # Step 2: Remove mount point (ignore failures)
  log "Step 2: Removing existing mount point..."
  rmdir "${PLEX_MEDIA_MOUNT}" 2>/dev/null || true
  log "✅ Mount point removal completed (or didn't exist)"

  # Step 3: Create mount point with proper ownership and permissions
  log "Step 3: Creating mount point with proper permissions..."
  # Create the specific mount point in user's home directory
  mkdir -p "${PLEX_MEDIA_MOUNT}"
  chmod 755 "${PLEX_MEDIA_MOUNT}"
  log "✅ Mount point created: ${PLEX_MEDIA_MOUNT} (user-owned 755)"

  # Step 4: Mount the NFS share
  log "Step 4: Mounting NFS share..."
  if sudo /sbin/mount_nfs -o resvport,rw,noowners,soft,bg,intr,actimeo=2,rsize=65536,wsize=65536 "${nfs_source}" "${PLEX_MEDIA_MOUNT}"; then
    log "✅ NFS mount successful"
  else
    log "❌ NFS mount failed"
    exit 1
  fi

  # Wait a moment for mount to be fully accessible
  sleep 2

  # Step 5: Test access for current user
  log "Step 5: Testing access..."
  if ! test_mount; then
    exit 1
  fi

  # Step 6: Create or replace $HOME symlink to mount dir
  ln -fs "${PLEX_MEDIA_MOUNT}/Media/" "${HOME}"

  log "✅ NAS media mount process completed successfully"
}

# Execute main function
main "$@"
exit 0
