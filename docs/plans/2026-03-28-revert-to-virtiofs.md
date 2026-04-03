# Revert to VirtioFS with Deferred Cleanup

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Switch the Transmission container's data volume back to VirtioFS (host NFS mount) for reliable connectivity, and prevent `.nfs.*` silly-rename issues by deferring file deletion until VirtioFS has released its file descriptors.

**Architecture:** The container's `/data` volume reverts from the VM-internal NFS mount (`/var/mnt/DSMedia`) to the host NFS mount via VirtioFS (`/Users/operator/.local/mnt/DSMedia`). The trigger watcher's `remove_torrent_from_transmission()` changes to `delete-local-data: false` so Transmission releases its FDs without attempting immediate deletion. A new periodic cleanup script sweeps `pending-move/` for orphaned directories that Transmission no longer tracks — confirming each candidate against Transmission's RPC before deleting. This separates "release the lock" from "delete the files" by hours.

**Tech Stack:** Bash, Podman, Transmission RPC, launchd, systemd (removal only)

**Why not VM-internal NFS:** Apple's vzNAT loses TCP forwarding to LAN hosts unpredictably (ICMP continues working). The NFS mount inside the VM drops, causing Permission denied (13). This has occurred three times in one session. The host-side NFS mount (managed by the existing watchdog) is rock-solid.

**Safety constraint:** The cleanup script must NEVER delete directories that contain un-processed torrents. Files may remain in `pending-move/` because FileBot failed, the trigger was missed, or the content is non-media (ISOs, etc.). Only directories confirmed absent from Transmission's torrent list are eligible for cleanup.

---

## Task 1: Revert Data Volume to VirtioFS in Setup Script

**Files:**

- Modify: `app-setup/podman-transmission-setup.sh`

### Step 1: Change NFS_MOUNT_POINT to host NFS path

Replace the VM-internal NFS mount point with the host path that VirtioFS exposes inside the VM.

In Section 2b (around line 337), change:

```bash
# Before:
NFS_MOUNT_POINT="/var/mnt/${NAS_SHARE_NAME}"

# After:
NFS_MOUNT_POINT="${OPERATOR_HOME}/.local/mnt/${NAS_SHARE_NAME}"
```

### Step 2: Remove Section 2b (VM-internal NFS mount setup)

Remove the entire block from line ~340 (`log "Configuring NFS mount inside Podman VM"`) through line ~377 (end of the mount verification `fi`). This includes:

- `mkdir -p` inside VM
- Writing the systemd mount unit
- `systemctl enable --now`
- Mount verification

### Step 3: Remove Section 2c (VM-internal NFS watchdog timer)

Remove the entire block from line ~379 (`set_section "VM-Internal NFS Watchdog"`) through line ~472 (end of timer verification). This includes:

- `nfs-watchdog.service` unit
- `nfs-watchdog.timer` unit
- `nfs-watchdog.sh` script
- Timer activation and verification

### Step 4: Update Section 10 header comment

Section 10 ("NAS Bind Mount Validation") validates VirtioFS visibility. Its comment and logic are already correct for the VirtioFS path — no changes needed, but verify it still references `${OPERATOR_HOME}/.local/mnt/DSMedia`.

### Step 5: Shellcheck and commit

```bash
shellcheck app-setup/podman-transmission-setup.sh
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(transmission): revert data volume to VirtioFS (host NFS)

VM-internal NFS mount was unreliable — Apple's vzNAT drops TCP
forwarding to LAN hosts unpredictably, causing Permission denied (13).
The host-side NFS mount (managed by the existing macOS watchdog) is
rock-solid. VirtioFS passthrough reintroduces .nfs.* silly-rename
files, handled by deferred cleanup in a follow-up commit."
```

---

## Task 2: Revert Data Volume in Startup Script

**Files:**

- Modify (on live server): `/Users/operator/.local/bin/podman-machine-start.sh`

### Step 1: Change the volume mount

In the `podman run` command, change:

```bash
# Before:
    -v "/var/mnt/DSMedia:/data" \

# After:
    -v "/Users/operator/.local/mnt/DSMedia:/data" \
```

### Step 2: Remove the NFS mount check block

Remove the two blocks that check/wait for the VM-internal NFS mount:

```bash
# Remove this block:
# Ensure NFS mount is active inside VM before starting containers
podman machine ssh transmission-vm -- "mountpoint -q '/var/mnt/DSMedia' || sudo systemctl start 'var-mnt-DSMedia.mount'"

# And this block:
# Wait for the NFS mount to be ready (up to 30 seconds)
for _ in {1..30}; do
    if podman machine ssh transmission-vm -- "mountpoint -q '/var/mnt/DSMedia'" 2>/dev/null; then
        break
    fi
    sleep 1
done
```

### Step 3: Update the setup script's startup template

The setup script generates `podman-machine-start.sh` from an inline template. Find the template in `podman-transmission-setup.sh` (around Section 9a) and make the same changes — revert the volume path and remove the VM NFS mount check blocks.

### Step 4: Commit

```bash
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(transmission): revert startup script to VirtioFS volume

Matches the setup script revert. Removes VM-internal NFS mount check
since the data volume now uses the host NFS path via VirtioFS."
```

---

## Task 3: Change Trigger Watcher to Not Delete Local Data

**Files:**

- Modify: `app-setup/templates/transmission-trigger-watcher.sh`

### Step 1: Change delete-local-data to false

In the `remove_torrent_from_transmission()` function (around line 97), change:

```bash
# Before:
  # Call torrent-remove with delete-local-data (FileBot already moved the media)
  local response
  response=$(curl -s "${TRANSMISSION_RPC_URL}" \
    -H "X-Transmission-Session-Id: ${session_id}" \
    --data-raw "{\"method\":\"torrent-remove\",\"arguments\":{\"ids\":[\"${torrent_hash}\"],\"delete-local-data\":true}}" \
    2>&1)

# After:
  # Remove torrent from Transmission WITHOUT deleting local data.
  # This closes Transmission's file descriptors on the download directory.
  # Actual file cleanup is deferred to pending-move-cleanup.sh to avoid
  # .nfs.* silly-rename files caused by VirtioFS holding FDs after close.
  local response
  response=$(curl -s "${TRANSMISSION_RPC_URL}" \
    -H "X-Transmission-Session-Id: ${session_id}" \
    --data-raw "{\"method\":\"torrent-remove\",\"arguments\":{\"ids\":[\"${torrent_hash}\"],\"delete-local-data\":false}}" \
    2>&1)
```

### Step 2: Update the log message

Change the log on success:

```bash
# Before:
    log "Torrent removed from Transmission: ${torrent_name}"

# After:
    log "Torrent removed from Transmission (files retained for deferred cleanup): ${torrent_name}"
```

### Step 3: Deploy to live server

```bash
sudo -u operator cp app-setup/templates/transmission-trigger-watcher.sh \
  /Users/operator/.local/bin/transmission-trigger-watcher.sh
```

Note: The trigger watcher is a long-running daemon. The deployed copy won't take effect until the daemon restarts (which happens naturally at next login, or manually via `launchctl kickstart`).

### Step 4: Commit

```bash
git add app-setup/templates/transmission-trigger-watcher.sh
git commit -m "fix(transmission): defer file deletion to avoid NFS silly-renames

Change delete-local-data from true to false in torrent removal. This
lets Transmission close its FDs without triggering .nfs.* silly-renames
through VirtioFS. Actual cleanup of pending-move/ is handled by a
separate periodic script that verifies each directory is no longer
tracked by Transmission before deleting."
```

---

## Task 4: Create Pending-Move Cleanup Script

**Files:**

- Create: `app-setup/templates/pending-move-cleanup.sh`

### Step 1: Write the cleanup script

```bash
#!/usr/bin/env bash
set -euo pipefail
#
# pending-move-cleanup.sh - Deferred cleanup of processed torrent directories
#
# Scans the Transmission pending-move directory for subdirectories that are
# no longer tracked by any active torrent. Only directories confirmed absent
# from Transmission's torrent list are removed.
#
# This exists because VirtioFS holds NFS file descriptors after the container
# closes them, causing .nfs.* silly-rename files if we delete immediately.
# By deferring deletion, VirtioFS has time to release its FDs.
#
# Safety: NEVER deletes a directory that Transmission still knows about.
# Files may remain in pending-move because FileBot failed, the trigger was
# missed, or the content is non-media (ISOs, etc.).
#
# Runs via com.<hostname>.pending-move-cleanup LaunchAgent (hourly).
#
# Template placeholders (replaced by podman-transmission-setup.sh at deploy time):
#   __SERVER_NAME__              → server hostname (e.g. TILSIT)
#   __TRANSMISSION_HOST_PORT__   → Transmission RPC port (e.g. 9091)
#   __OPERATOR_HOME__            → operator home directory
#
# Author: Andrew Rich <andrew.rich@gmail.com>

SERVER_NAME="__SERVER_NAME__"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"

PENDING_MOVE="${HOME}/.local/mnt/DSMedia/Media/Torrents/pending-move"
TRANSMISSION_RPC_URL="http://localhost:__TRANSMISSION_HOST_PORT__/transmission/rpc"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-pending-move-cleanup.log"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [pending-move-cleanup] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

# Get all torrent download directories from Transmission RPC.
# Returns newline-separated list of TR_TORRENT_NAME values.
get_active_torrent_names() {
  # Get CSRF token
  local session_id
  session_id=$(curl -s -D - "${TRANSMISSION_RPC_URL}" 2>/dev/null \
    | awk 'tolower($0) ~ /^x-transmission-session-id:/{gsub(/\r/,""); print $2; exit}')

  if [[ -z "${session_id}" ]]; then
    # Can't reach Transmission — return failure so we skip cleanup this cycle
    return 1
  fi

  # Query all torrents for their names
  local response
  response=$(curl -s "${TRANSMISSION_RPC_URL}" \
    -H "X-Transmission-Session-Id: ${session_id}" \
    --data-raw '{"method":"torrent-get","arguments":{"fields":["name"]}}' \
    2>&1)

  # Extract torrent names (simple grep — one name per line)
  printf '%s' "${response}" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"$//'
}

# --- Main ---

if [[ ! -d "${PENDING_MOVE}" ]]; then
  # pending-move doesn't exist (NAS not mounted?) — skip silently
  exit 0
fi

# Get active torrent names; if Transmission is unreachable, skip this cycle entirely
active_names=$(get_active_torrent_names) || {
  log "Transmission RPC unreachable — skipping cleanup cycle"
  exit 0
}

cleaned=0
skipped=0

# Process each subdirectory in pending-move
while IFS= read -r -d '' entry; do
  entry_name=$(basename "${entry}")

  # Skip dotfiles (like .DS_Store)
  [[ "${entry_name}" == .* ]] && continue

  # Check if this name matches any active torrent
  if printf '%s\n' "${active_names}" | grep -qxF "${entry_name}"; then
    skipped=$((skipped + 1))
    continue
  fi

  # Not tracked by Transmission — safe to remove
  if rm -rf "${entry}" 2>/dev/null; then
    log "Cleaned: ${entry_name}"
    cleaned=$((cleaned + 1))
  else
    log "WARNING: Failed to remove: ${entry_name}"
  fi
done < <(find "${PENDING_MOVE}" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -print0 2>/dev/null)

if [[ "${cleaned}" -gt 0 ]] || [[ "${skipped}" -gt 0 ]]; then
  log "Cycle complete: ${cleaned} cleaned, ${skipped} still tracked by Transmission"
fi
```

### Step 2: Shellcheck

```bash
shellcheck app-setup/templates/pending-move-cleanup.sh
```

### Step 3: Commit

```bash
git add app-setup/templates/pending-move-cleanup.sh
git commit -m "feat(transmission): add deferred pending-move cleanup script

Hourly sweep of pending-move/ that only removes directories confirmed
absent from Transmission's torrent list via RPC. Prevents deletion of
un-processed torrents, failed FileBot runs, and non-media files (ISOs).

Companion to the delete-local-data:false change — separates 'release
the lock' (torrent removal) from 'delete the files' (this script)."
```

---

## Task 5: Add Cleanup Deployment to Setup Script

**Files:**

- Modify: `app-setup/podman-transmission-setup.sh`

### Step 1: Add cleanup script deployment

After the trigger watcher deployment (Section 7 / "Deploy Trigger Watcher"), add a new section:

```bash
# ---------------------------------------------------------------------------
# Section 7b: Deploy pending-move cleanup script
# ---------------------------------------------------------------------------

set_section "Deploy Pending-Move Cleanup Script"

CLEANUP_TEMPLATE="${SCRIPT_DIR}/templates/pending-move-cleanup.sh"
CLEANUP_DEST="${OPERATOR_HOME}/.local/bin/pending-move-cleanup.sh"

if [[ ! -f "${CLEANUP_TEMPLATE}" ]]; then
  collect_error "Cleanup template not found: ${CLEANUP_TEMPLATE}"
else
  log "Deploying pending-move-cleanup.sh"

  sudo sed \
    -e "s|__SERVER_NAME__|${HOSTNAME}|g" \
    -e "s|__TRANSMISSION_HOST_PORT__|${HOST_PORT}|g" \
    -e "s|__OPERATOR_HOME__|${OPERATOR_HOME}|g" \
    "${CLEANUP_TEMPLATE}" | sudo tee "${CLEANUP_DEST}" >/dev/null

  sudo chown "${OPERATOR_USERNAME}:staff" "${CLEANUP_DEST}"
  sudo chmod 755 "${CLEANUP_DEST}"
  log "✅ pending-move-cleanup.sh deployed"
fi
```

### Step 2: Add cleanup LaunchAgent

In Section 9 (LaunchAgents), after the trigger watcher plist, add:

```bash
# --- 9c: Pending-move cleanup timer ---

CLEANUP_PLIST="${LAUNCHAGENT_DIR}/com.${HOSTNAME_LOWER}.pending-move-cleanup.plist"
log "Creating LaunchAgent: ${CLEANUP_PLIST}"

sudo -iu "${OPERATOR_USERNAME}" tee "${CLEANUP_PLIST}" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.pending-move-cleanup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${OPERATOR_HOME}/.local/bin/pending-move-cleanup.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-pending-move-cleanup.log</string>
  <key>StandardErrorPath</key>
  <string>${OPERATOR_HOME}/.local/state/${HOSTNAME_LOWER}-pending-move-cleanup.log</string>
</dict>
</plist>
PLIST

sudo chown "${OPERATOR_USERNAME}:staff" "${CLEANUP_PLIST}"
sudo chmod 644 "${CLEANUP_PLIST}"

if sudo plutil -lint "${CLEANUP_PLIST}" >/dev/null 2>&1; then
  log "✅ pending-move-cleanup LaunchAgent created (hourly)"
else
  collect_error "Invalid plist syntax in ${CLEANUP_PLIST}"
fi
```

### Step 3: Shellcheck and commit

```bash
shellcheck app-setup/podman-transmission-setup.sh
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(transmission): deploy cleanup script and LaunchAgent

Adds pending-move-cleanup.sh deployment and an hourly LaunchAgent
to podman-transmission-setup.sh."
```

---

## Task 6: Live Cutover

### Step 1: Ensure host NFS mount is active

```bash
mountpoint -q /Users/operator/.local/mnt/DSMedia && echo "Host NFS OK"
```

### Step 2: Stop and remove current container

```bash
sudo -iu operator podman stop transmission-vpn
sudo -iu operator podman rm transmission-vpn
```

### Step 3: Recreate container with VirtioFS volume

```bash
sudo -iu operator podman run -d \
    --name transmission-vpn \
    --privileged \
    --device /dev/net/tun:/dev/net/tun \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    -v "/Users/operator/.local/mnt/DSMedia:/data" \
    -v "/Users/operator/containers/transmission/scripts:/scripts" \
    -v "/Users/operator/containers/transmission/config:/config" \
    -v "/Users/operator/containers/transmission/watch:/watch" \
    -p "9091:9091" \
    --restart unless-stopped \
    --health-cmd "curl -sf --max-time 5 http://localhost:9091/transmission/web/" \
    --health-interval 60s \
    --health-start-period 120s \
    --health-retries 3 \
    --health-on-failure restart \
    --env-file "/Users/operator/containers/transmission/.env" \
    -e OPENVPN_PROVIDER=PIA \
    -e "OPENVPN_CONFIG=panama" \
    -e "LOCAL_NETWORK=10.0.15.0/24" \
    -e "PUID=502" \
    -e "PGID=20" \
    -e "TZ=America/Los_Angeles" \
    -e TRANSMISSION_DOWNLOAD_DIR=/data/Media/Torrents/pending-move \
    -e TRANSMISSION_INCOMPLETE_DIR=/data/Media/Torrents/incomplete \
    -e TRANSMISSION_WATCH_DIR=/watch \
    -e TRANSMISSION_WATCH_DIR_ENABLED=true \
    -e TRANSMISSION_RATIO_LIMIT_ENABLED=false \
    -e TRANSMISSION_ENCRYPTION=2 \
    -e TRANSMISSION_BLOCKLIST_ENABLED=true \
    -e "TRANSMISSION_BLOCKLIST_URL=https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz" \
    -e TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false \
    -e TRANSMISSION_RPC_WHITELIST_ENABLED=false \
    -e TRANSMISSION_SCRIPT_TORRENT_DONE_ENABLED=true \
    -e TRANSMISSION_SCRIPT_TORRENT_DONE_FILENAME=/scripts/transmission-post-done.sh \
    -e CREATE_TUN_DEVICE=false \
    -e LOG_TO_STDOUT=true \
    haugene/transmission-openvpn:latest
```

### Step 4: Wait for healthy, verify NFS access

```bash
# Wait for healthy
podman inspect --format '{{.State.Health.Status}}' transmission-vpn

# Verify NFS access inside container
sudo -iu operator podman exec transmission-vpn ls /data/Media/Torrents/

# Verify web UI
curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost:9091/transmission/web/
```

### Step 5: Deploy cleanup script and LaunchAgent to live server

```bash
# Deploy cleanup script (substitute placeholders)
sudo sed \
  -e 's|__SERVER_NAME__|TILSIT|g' \
  -e 's|__TRANSMISSION_HOST_PORT__|9091|g' \
  -e 's|__OPERATOR_HOME__|/Users/operator|g' \
  app-setup/templates/pending-move-cleanup.sh \
  | sudo tee /Users/operator/.local/bin/pending-move-cleanup.sh >/dev/null
sudo chown operator:staff /Users/operator/.local/bin/pending-move-cleanup.sh
sudo chmod 755 /Users/operator/.local/bin/pending-move-cleanup.sh

# Deploy LaunchAgent
# (use the plist content from Task 5 Step 2 with placeholders substituted)

# Load the LaunchAgent
sudo -iu operator launchctl bootstrap gui/$(id -u operator) \
  /Users/operator/Library/LaunchAgents/com.tilsit.pending-move-cleanup.plist
```

### Step 6: Deploy updated trigger watcher

```bash
# The trigger watcher template was updated in Task 3 — deploy it
sudo sed \
  -e 's|__SERVER_NAME__|TILSIT|g' \
  -e 's|__TRANSMISSION_HOST_PORT__|9091|g' \
  app-setup/templates/transmission-trigger-watcher.sh \
  | sudo tee /Users/operator/.local/bin/transmission-trigger-watcher.sh >/dev/null
sudo chown operator:staff /Users/operator/.local/bin/transmission-trigger-watcher.sh
sudo chmod 755 /Users/operator/.local/bin/transmission-trigger-watcher.sh

# Restart the trigger watcher daemon to pick up the change
sudo -iu operator launchctl kickstart -k gui/$(id -u operator)/com.tilsit.transmission-trigger-watcher
```

### Step 7: Test with a torrent

Add a test torrent. Verify:

1. Download completes to `/data/Media/Torrents/pending-move/`
2. Post-done trigger fires
3. Trigger watcher invokes FileBot
4. Torrent is removed from Transmission (without deleting files)
5. Files remain in `pending-move/` temporarily
6. Cleanup script (run manually to test): `sudo -iu operator bash /Users/operator/.local/bin/pending-move-cleanup.sh`
7. Orphaned directory is cleaned up

### Step 8: Clean up VM-internal NFS artifacts

```bash
# Remove systemd units from inside the VM (no longer needed)
sudo -iu operator podman machine ssh transmission-vm -- \
  "sudo systemctl disable --now var-mnt-DSMedia.mount nfs-watchdog.timer nfs-watchdog.service 2>/dev/null; \
   sudo rm -f /etc/systemd/system/var-mnt-DSMedia.mount /etc/systemd/system/nfs-watchdog.* /usr/local/bin/nfs-watchdog.sh; \
   sudo systemctl daemon-reload"
```
