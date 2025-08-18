#!/bin/bash

# mount-nas-media.sh - Persistent SMB mount script for NAS media access
# This script is designed to be called by a LaunchDaemon at boot time
# to provide persistent SMB mounting for both admin and operator users.

set -euo pipefail

# Configuration - these will be set during installation
NAS_HOSTNAME="__NAS_HOSTNAME__"
NAS_SHARE_NAME="__NAS_SHARE_NAME__"
PLEX_NAS_USERNAME="__PLEX_NAS_USERNAME__"
PLEX_NAS_PASSWORD="__PLEX_NAS_PASSWORD__"
PLEX_MEDIA_MOUNT="__PLEX_MEDIA_MOUNT__"
SERVER_NAME="__SERVER_NAME__"

# Logging configuration
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
LOG_FILE="/var/log/${HOSTNAME_LOWER}-mount.log"

# Ensure log file exists with proper permissions
touch "${LOG_FILE}"
chmod 644 "${LOG_FILE}"

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
    ((attempt++))
  done

  log "❌ Failed to establish network connectivity to ${NAS_HOSTNAME} after ${max_attempts} attempts"
  return 1
}

# Check if mount already exists
is_already_mounted() {
  mount | grep -q "${PLEX_MEDIA_MOUNT}"
}

# Create mount point with proper permissions
create_mount_point() {
  if [[ ! -d "${PLEX_MEDIA_MOUNT}" ]]; then
    log "Creating mount point: ${PLEX_MEDIA_MOUNT}"
    mkdir -p "${PLEX_MEDIA_MOUNT}"

    # Set ownership to admin:staff for shared access
    chown "root:staff" "${PLEX_MEDIA_MOUNT}"
    chmod 775 "${PLEX_MEDIA_MOUNT}"
    log "✅ Mount point created with shared permissions"
  else
    log "Mount point ${PLEX_MEDIA_MOUNT} already exists"
  fi
}

# Perform the SMB mount
mount_smb_share() {
  log "Mounting SMB share: //${PLEX_NAS_USERNAME}:***@${NAS_HOSTNAME}/${NAS_SHARE_NAME}"

  # URL-encode password to handle special characters
  local encoded_password
  encoded_password=$(printf '%s' "${PLEX_NAS_PASSWORD}" | sed 's/@/%40/g; s/:/%3A/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g')

  local mount_url="//${PLEX_NAS_USERNAME}:${encoded_password}@${NAS_HOSTNAME}/${NAS_SHARE_NAME}"

  if mount -t smbfs -o soft,nobrowse,noowners,file_mode=0664,dir_mode=0775 "${mount_url}" "${PLEX_MEDIA_MOUNT}" 2>/dev/null; then
    log "✅ SMB mount successful"

    # Verify mount and test access
    if mount | grep -q "${PLEX_MEDIA_MOUNT}"; then
      log "✅ Mount verified in system mount table"

      # Test accessibility
      if ls "${PLEX_MEDIA_MOUNT}" >/dev/null 2>&1; then
        local file_count
        file_count=$(find "${PLEX_MEDIA_MOUNT}" -maxdepth 1 -type f -o -type d | tail -n +2 | wc -l 2>/dev/null || echo "0")
        log "✅ Media directory accessible with ${file_count} items"

        # Test write access
        local test_file
        test_file="${PLEX_MEDIA_MOUNT}/mount-test-$(date +%Y%m%d-%H%M%S)"
        if touch "${test_file}" 2>/dev/null; then
          log "✅ Write access confirmed"
          rm -f "${test_file}" 2>/dev/null || log "⚠️  Could not clean up test file ${test_file}"
        else
          log "⚠️  Mount is read-only or write access denied"
        fi

        return 0
      else
        log "⚠️  Mount succeeded but directory not accessible"
        return 1
      fi
    else
      log "⚠️  Mount command succeeded but mount not visible in system"
      return 1
    fi
  else
    log "❌ SMB mount failed"
    log "   Possible issues:"
    log "   - SMB share connection limit reached"
    log "   - Incorrect credentials"
    log "   - Network connectivity issues"
    return 1
  fi
}

# Main execution
main() {
  log "Starting NAS media mount process"
  log "Target: ${PLEX_MEDIA_MOUNT}"
  log "Source: //${PLEX_NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME}"

  # Check if already mounted
  if is_already_mounted; then
    log "✅ SMB share already mounted at ${PLEX_MEDIA_MOUNT}"
    return 0
  fi

  # Wait for network
  if ! wait_for_network; then
    log "❌ Cannot proceed without network connectivity"
    exit 1
  fi

  # Create mount point
  create_mount_point

  # Attempt mount with retry logic
  local max_mount_attempts=3
  local mount_attempt=1

  while [[ ${mount_attempt} -le ${max_mount_attempts} ]]; do
    log "Mount attempt ${mount_attempt}/${max_mount_attempts}"

    if mount_smb_share; then
      log "✅ NAS media mount completed successfully"
      exit 0
    fi

    if [[ ${mount_attempt} -lt ${max_mount_attempts} ]]; then
      log "   Retrying in 10 seconds..."
      sleep 10
    fi

    ((mount_attempt++))
  done

  log "❌ Failed to mount NAS media after ${max_mount_attempts} attempts"
  exit 1
}

# Execute main function
main "$@"
