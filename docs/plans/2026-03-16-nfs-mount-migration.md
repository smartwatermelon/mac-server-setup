# NFS Mount Migration: DSMedia Share — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace SMB mount with NFS for the DSMedia share to eliminate VirtioFS/SMB `.smbdelete` lock conflicts.

**Architecture:** Swap the mount command in `mount-nas-media.sh` from `mount_smbfs` to `mount -t nfs`. Remove credential embedding (NFS uses host-based auth). Add `NAS_VOLUME` config variable for the Synology export path. Same mountpoint, same LaunchAgent, same downstream consumers.

**Tech Stack:** macOS NFS client, Synology NFS server, bash, LaunchAgents

---

## Prerequisite (Manual — Already Done)

Synology DSM: Enable NFS, create export rule for DSMedia:

- Hostname/IP: `10.0.12.0/22`, Privilege: Read/Write, Squash: Map all to admin, Security: sys, Async: enabled

---

### Task 1: Verify NFS Mount Works Manually

Before changing any code, confirm the Synology NFS export is accessible.

**Step 1: Test NFS mount to a temp path**

```bash
sudo mkdir -p /tmp/nfs-test
sudo mount -t nfs -o resvport,rw,soft romano.local:/volume1/DSMedia /tmp/nfs-test
```

Expected: Mount succeeds without error.

**Step 2: Verify contents match SMB mount**

```bash
ls /tmp/nfs-test/Media/
```

Expected: Same directory listing as the current SMB mount (`Movies`, `TV Shows`, `Torrents`, etc.)

**Step 3: Test file creation and deletion**

```bash
touch /tmp/nfs-test/Media/Torrents/nfs-test-file
rm /tmp/nfs-test/Media/Torrents/nfs-test-file
```

Expected: Both succeed without error or `.smbdelete` remnants.

**Step 4: Clean up test mount**

```bash
sudo umount /tmp/nfs-test
sudo rmdir /tmp/nfs-test
```

**Step 5: STOP if any step above failed.** Debug NFS export config on Synology before proceeding.

---

### Task 2: Add `NAS_VOLUME` to Config Template

**Files:**

- Modify: `config/config.conf.template:22-24`

**Step 1: Add NAS_VOLUME variable**

After `NAS_SHARE_NAME="DSMedia"` (line 24), add:

```bash
NAS_VOLUME="volume1"              # Synology volume name for NFS export path
```

**Step 2: Commit**

```bash
git add config/config.conf.template
git commit -m "feat(config): add NAS_VOLUME for NFS export path"
```

---

### Task 3: Rewrite Mount Script Template for NFS

**Files:**

- Modify: `app-setup/templates/mount-nas-media.sh`

**Step 1: Replace the entire template with the NFS version**

The new script keeps the same structure (set -euo pipefail, logging, wait_for_network, test_mount, main with numbered steps) but replaces the SMB-specific parts:

```bash
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
  if ! mount -t nfs | grep -q "${PLEX_MEDIA_MOUNT}"; then
    log "⚠️  NFS mount not visible in system mount table"
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
  umount "${PLEX_MEDIA_MOUNT}" 2>/dev/null || true
  log "✅ Unmount completed (or was not mounted)"

  # Step 2: Remove mount point (ignore failures)
  log "Step 2: Removing existing mount point..."
  rmdir "${PLEX_MEDIA_MOUNT}" 2>/dev/null || true
  log "✅ Mount point removal completed (or didn't exist)"

  # Step 3: Create mount point with proper ownership and permissions
  log "Step 3: Creating mount point with proper permissions..."
  mkdir -p "${PLEX_MEDIA_MOUNT}"
  chmod 755 "${PLEX_MEDIA_MOUNT}"
  log "✅ Mount point created: ${PLEX_MEDIA_MOUNT} (user-owned 755)"

  # Step 4: Mount the NFS share
  log "Step 4: Mounting NFS share..."

  if mount -t nfs -o resvport,rw,soft,bg,intr,rsize=65536,wsize=65536 "${nfs_source}" "${PLEX_MEDIA_MOUNT}"; then
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
```

**Step 2: Verify shellcheck passes**

```bash
shellcheck app-setup/templates/mount-nas-media.sh
```

Expected: No errors, warnings, or info.

**Step 3: Commit**

```bash
git add app-setup/templates/mount-nas-media.sh
git commit -m "feat(mount): replace SMB with NFS in mount-nas-media template

NFS eliminates VirtioFS/SMB oplock conflict that caused .smbdelete
ghost files when deleting torrents while Podman VM is running."
```

---

### Task 4: Update `plex-setup.sh` — Remove Credential Embedding, Add NAS_VOLUME

**Files:**

- Modify: `app-setup/plex-setup.sh:378-549` (the `setup_persistent_smb_mount` function)
- Modify: `app-setup/plex-setup.sh:1614-1622` (troubleshooting output)

**Step 1: Rename function and strip credential logic**

Rename `setup_persistent_smb_mount` → `setup_persistent_nfs_mount`.

Replace the function body. The new version:

- Removes: keychain retrieval (lines 398-424), credential splitting, `__PLEX_NAS_USERNAME__`/`__PLEX_NAS_PASSWORD__` sed substitutions, `unset plex_nas_username plex_nas_password`
- Adds: `__NAS_VOLUME__` substitution (from `config.conf`)
- Updates: all log messages from "SMB" → "NFS"
- Keeps: template copy, `__NAS_HOSTNAME__`/`__NAS_SHARE_NAME__`/`__SERVER_NAME__` substitutions, deploy_user_mount function, LaunchAgent plist creation, immediate mount test

**Step 2: Update the function call site** (line 1511)

Change `setup_persistent_smb_mount` → `setup_persistent_nfs_mount`

**Step 3: Update troubleshooting output** (lines 1614-1622)

Replace SMB-specific hints with NFS equivalents:

- Manual mount command: `mount -t nfs -o resvport,rw,soft romano.local:/volume1/DSMedia '${PLEX_MEDIA_MOUNT}'`
- Check mounts: `mount -t nfs`
- Remove "Too many users" SMB error hint

**Step 4: Commit**

```bash
git add app-setup/plex-setup.sh
git commit -m "feat(plex-setup): switch mount deployment from SMB to NFS

Removes credential embedding (NFS uses host-based auth).
Adds NAS_VOLUME template substitution for export path."
```

---

### Task 5: Live Cutover — Stop Services, Switch Mounts, Restart

**This task is performed manually with human confirmation at each step.**

**Step 1: Stop Transmission container and Podman VM**

```bash
sudo -H -u operator podman stop transmission-vpn
sudo -H -u operator podman machine stop transmission-vm
```

**Step 2: Unmount existing SMB mounts for both users**

```bash
# Operator
sudo umount /Users/operator/.local/mnt/DSMedia 2>/dev/null || true

# Admin (if mounted)
umount ~/.local/mnt/DSMedia 2>/dev/null || true
```

**Step 3: Deploy and run updated mount script for operator**

```bash
# Copy the updated template and substitute values
cp app-setup/templates/mount-nas-media.sh /tmp/mount-nas-media-configured.sh
sed -i '' \
  -e 's|__NAS_HOSTNAME__|romano.local|g' \
  -e 's|__NAS_SHARE_NAME__|DSMedia|g' \
  -e 's|__NAS_VOLUME__|volume1|g' \
  -e 's|__SERVER_NAME__|TILSIT|g' \
  /tmp/mount-nas-media-configured.sh

# Deploy to operator
sudo -u operator cp /tmp/mount-nas-media-configured.sh /Users/operator/.local/bin/mount-nas-media.sh
sudo -u operator chmod 700 /Users/operator/.local/bin/mount-nas-media.sh

# Run it
sudo -iu operator /Users/operator/.local/bin/mount-nas-media.sh
```

**Step 4: Verify NFS mount for operator**

```bash
mount -t nfs | grep DSMedia
sudo ls /Users/operator/.local/mnt/DSMedia/Media/
```

Expected: NFS mount visible, Media directories listed.

**Step 5: Deploy and run updated mount script for admin**

```bash
sudo -u andrewrich cp /tmp/mount-nas-media-configured.sh ~/.local/bin/mount-nas-media.sh
chmod 700 ~/.local/bin/mount-nas-media.sh
~/.local/bin/mount-nas-media.sh
```

**Step 6: Verify NFS mount for admin**

```bash
mount -t nfs | grep DSMedia
ls ~/Media/
```

**Step 7: Clean up**

```bash
rm /tmp/mount-nas-media-configured.sh
```

**Step 8: Restart Podman VM and Transmission**

```bash
sudo -H -u operator podman machine start transmission-vm
sudo -H -u operator podman start transmission-vpn
```

**Step 9: Verify the original problem is fixed**

```bash
# Create a test file
sudo touch /Users/operator/.local/mnt/DSMedia/Media/Torrents/pending-move/nfs-delete-test

# Delete it while VM is running
sudo rm /Users/operator/.local/mnt/DSMedia/Media/Torrents/pending-move/nfs-delete-test

# Verify no .smbdelete remnant
sudo ls -la /Users/operator/.local/mnt/DSMedia/Media/Torrents/pending-move/
```

Expected: File deletes cleanly, no `.smbdelete*` files.

**Step 10: Verify Plex still sees its libraries**

Open Plex web UI (<http://localhost:32400/web>) and confirm libraries are accessible with no re-scan triggered.

---

### Task 6: Commit the Plan Update

```bash
git add docs/plans/2026-03-16-nfs-mount-migration.md
git commit -m "docs: update NFS migration plan with implementation details"
```

---

## Revert Plan

If NFS causes issues at any point after cutover:

```bash
# 1. Stop services
sudo -H -u operator podman stop transmission-vpn
sudo -H -u operator podman machine stop transmission-vm

# 2. Unmount NFS
sudo umount /Users/operator/.local/mnt/DSMedia 2>/dev/null || true
umount ~/.local/mnt/DSMedia 2>/dev/null || true

# 3. Restore SMB mount script from git
git show HEAD~3:app-setup/templates/mount-nas-media.sh > /tmp/mount-nas-media-smb.sh

# 4. Re-embed credentials and deploy (needs keychain values)
#    Substitute __PLEX_NAS_USERNAME__ and __PLEX_NAS_PASSWORD__ manually
#    or re-run plex-setup.sh from the pre-NFS commit

# 5. Restart everything
sudo -iu operator /Users/operator/.local/bin/mount-nas-media.sh
sudo -H -u operator podman machine start transmission-vm
sudo -H -u operator podman start transmission-vpn
```

The SMB service on Synology was never disabled — both protocols coexist. Rollback only requires swapping the mount script back.
