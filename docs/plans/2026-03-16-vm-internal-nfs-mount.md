# VM-Internal NFS Mount Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Mount NFS directly inside the Podman VM so Transmission bypasses VirtioFS, eliminating stale file descriptor / `.nfs.*` silly-rename issues.

**Architecture:** Replace the VirtioFS volume bind for DSMedia with a direct NFS mount inside the Fedora CoreOS VM. A systemd `.mount` unit persists the NFS mount across VM reboots. The compose volume changes from the host path to the VM-internal mount path. The host-side NFS mount remains for Plex, Finder, and FileBot.

**Tech Stack:** systemd mount units, Podman machine SSH, NFS, compose.yml

**Prerequisite (already done):** Synology NFS export for `10.0.12.0/22` has "Allow connections from non-privileged ports" enabled (required because VM traffic is NAT'd and port-remapped by Apple's vzNAT).

---

## Task 1: Revert `transmission-post-done.sh` — Remove Torrent-Remove RPC

The torrent-remove RPC was a workaround for VirtioFS FD caching. With VirtioFS removed from the data path, it's no longer needed — and it prevents seeding.

**Files:**

- Modify: `app-setup/templates/transmission-post-done.sh`

### Step 1: Revert to the simple trigger-only version

Replace the entire file with:

```bash
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
```

### Step 2: Deploy to live container

```bash
sudo -u operator cp app-setup/templates/transmission-post-done.sh \
  /Users/operator/containers/transmission/scripts/transmission-post-done.sh
sudo -u operator chmod 755 /Users/operator/containers/transmission/scripts/transmission-post-done.sh
```

### Step 3: Commit post-done revert

```bash
git add app-setup/templates/transmission-post-done.sh
git commit -m "revert(transmission): remove torrent-remove RPC from post-done

The torrent-remove was a workaround for VirtioFS FD caching. With NFS
mounted directly inside the VM (bypassing VirtioFS), it's no longer
needed — and it prevented seeding."
```

---

## Task 2: Add NFS Mount Setup Inside VM to `podman-transmission-setup.sh`

Add a new section that SSHs into the VM and creates a persistent systemd mount unit for the NFS share.

**Files:**

- Modify: `app-setup/podman-transmission-setup.sh` (insert new section after VM start, before compose deploy)

### Step 1: Find the insertion point

The new section goes after the VM is started (line ~320) and before the compose.yml is deployed. Look for the section after `podman machine start` and before `Section 5` or the compose template deployment.

### Step 2: Add the NFS mount section

Insert a new section that:

1. Creates `/mnt/DSMedia` inside the VM
2. Writes a systemd mount unit at `/etc/systemd/system/mnt-DSMedia.mount`
3. Enables and starts the mount
4. Verifies the mount works

The systemd mount unit content:

```ini
[Unit]
Description=NFS mount for DSMedia share
After=network-online.target
Wants=network-online.target

[Mount]
What=romano.local:/volume2/DSMedia
Where=/mnt/DSMedia
Type=nfs
Options=rw,soft,intr,actimeo=2,rsize=65536,wsize=65536

[Install]
WantedBy=local-fs.target
```

**Important:** The `What=` value must use template placeholders (`__NAS_HOSTNAME__`, `__NAS_VOLUME__`, `__NAS_SHARE_NAME__`) so the setup script substitutes the correct values. The mount unit file is written via `podman machine ssh` with heredoc, and placeholders are expanded by the shell at deploy time (not by systemd).

### Step 3: Shellcheck and commit

```bash
shellcheck app-setup/podman-transmission-setup.sh
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(transmission): mount NFS directly inside Podman VM

Bypasses VirtioFS for NFS-backed data, eliminating stale file descriptor
caching that caused .nfs.* silly-rename files on the host. The VM mounts
the NAS share directly via a persistent systemd .mount unit."
```

---

## Task 3: Change Compose Volume from VirtioFS to VM-Internal NFS

**Files:**

- Modify: `app-setup/containers/transmission/compose.yml:52`

### Step 1: Change the volume

```yaml
# Before:
      - __OPERATOR_HOME__/.local/mnt/DSMedia:/data

# After:
      - /mnt/DSMedia:/data
```

**Step 2: Update the placeholder reference comment** (lines 4-15)

Remove `__OPERATOR_HOME__` from the placeholder reference since it's no longer used in the data volume (it's still used by the other three volumes).

Actually — `__OPERATOR_HOME__` is still used by the scripts, config, and watch volumes. Keep the comment. Just change the volume line.

### Step 3: Commit compose change

```bash
git add app-setup/containers/transmission/compose.yml
git commit -m "feat(transmission): use VM-internal NFS mount for /data volume

Replaces VirtioFS passthrough (host NFS → VirtioFS → container) with
direct NFS mount inside the VM (NFS → container). Eliminates Apple
Virtualization framework FD caching that caused .nfs.* silly-renames."
```

---

## Task 4: Update `podman-machine-start.sh` to Ensure NFS Mount Before Compose Up

The login-time startup script needs to ensure the VM's NFS mount is active before starting the container stack.

**Files:**

- Modify: `app-setup/podman-transmission-setup.sh` (the `podman-machine-start.sh` template at lines ~465-494)

### Step 1: Add NFS mount check after machine start, before compose up

After the Podman socket wait loop and before the `podman compose` line, add:

```bash
# Ensure NFS mount is active inside VM before starting containers
podman machine ssh transmission-vm -- "mountpoint -q /mnt/DSMedia || sudo systemctl start mnt-DSMedia.mount"
```

### Step 2: Commit startup script

```bash
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(transmission): ensure VM NFS mount before compose up at login"
```

---

## Task 5: Live Cutover and Verification

### Step 1: Stop container and recreate with new compose

```bash
sudo -H -u operator podman stop transmission-vpn
sudo -H -u operator podman rm transmission-vpn
```

### Step 2: Set up NFS mount inside VM

```bash
sudo -H -u operator podman machine ssh transmission-vm -- "sudo mkdir -p /mnt/DSMedia"
sudo -H -u operator podman machine ssh transmission-vm -- "sudo tee /etc/systemd/system/mnt-DSMedia.mount" <<'EOF'
[Unit]
Description=NFS mount for DSMedia share
After=network-online.target
Wants=network-online.target

[Mount]
What=romano.local:/volume2/DSMedia
Where=/mnt/DSMedia
Type=nfs
Options=rw,soft,intr,actimeo=2,rsize=65536,wsize=65536

[Install]
WantedBy=local-fs.target
EOF

sudo -H -u operator podman machine ssh transmission-vm -- "sudo systemctl daemon-reload && sudo systemctl enable --now mnt-DSMedia.mount"
```

### Step 3: Verify NFS mount

```bash
sudo -H -u operator podman machine ssh transmission-vm -- "mountpoint /mnt/DSMedia && ls /mnt/DSMedia/Media/Torrents/"
```

### Step 4: Deploy updated compose and start container

```bash
# Copy updated compose.yml (with /mnt/DSMedia:/data)
# Then start
sudo -H -u operator podman compose \
  -f /Users/operator/containers/transmission/compose.yml \
  --env-file /Users/operator/containers/transmission/.env up -d
```

### Step 5: Verify container sees NFS mount

```bash
sudo -H -u operator podman exec transmission-vpn ls /data/Media/Torrents/
```

### Step 6: Test the full pipeline

Add a test torrent. Verify:

1. Download completes to `/data/Media/Torrents/pending-move/` (NFS inside VM)
2. Post-done trigger fires
3. Trigger watcher picks it up
4. FileBot processes and moves the file
5. No `.nfs.*` silly-rename files remain
6. Directory can be deleted from Finder without locks

### Step 7: Clean up old Big Buck Bunny directory if still present

```bash
sudo rm -rf "/Users/operator/.local/mnt/DSMedia/Media/Torrents/pending-move/Big Buck Bunny"
```
