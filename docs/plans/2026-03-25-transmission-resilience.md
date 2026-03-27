# Transmission Resilience: NFS Watchdog + Health Check

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Auto-recover Transmission when the NFS mount goes stale *or is not mounted* or the daemon becomes unresponsive, preventing the manual restart that was needed on 2026-03-25.

**Architecture:** Two independent resilience layers. (1) A systemd timer inside the Podman VM that tests the NFS mount every 2 minutes and recovers from two failure modes: stale/hung mounts (where `stat` hangs) and unmounted directories (where the mount unit failed but the empty directory remains). (2) A Podman health check on the container that curls the Transmission RPC endpoint and auto-restarts the container after 3 consecutive failures. Both are deployed by `podman-transmission-setup.sh`.

> **Gotcha (2026-03-26):** `stat` succeeds on an empty directory — it only detects stale mounts where the NFS server disappeared mid-session. When the systemd mount unit times out or fails, the mount point reverts to a plain empty directory and `stat` returns instantly. You **must** pair `stat` with `mountpoint -q` to catch both failure modes. This applies to both the health check and the recovery verification. See PR #98.

**Tech Stack:** systemd (timer + service units), Podman health check flags, bash

---

## Task 1: Add NFS watchdog systemd units to the setup script

**Files:**

- Modify: `app-setup/podman-transmission-setup.sh:367-378` (after NFS mount verification in Section 2b)

### Step 1: Add the NFS watchdog deployment after the existing NFS mount verification block

Insert a new subsection after line 378 (the `fi` closing the NFS mount verification). This writes two systemd units into the VM and enables the timer.

Find this block (lines 367-378):

```bash
# Enable and start
sudo -iu "${OPERATOR_USERNAME}" podman machine ssh transmission-vm -- \
  "sudo systemctl daemon-reload && sudo systemctl enable --now '${MOUNT_UNIT_NAME}'"

# Verify
if sudo -iu "${OPERATOR_USERNAME}" podman machine ssh transmission-vm -- \
  "mountpoint -q '${NFS_MOUNT_POINT}'"; then
  log "✅ NFS mount active inside VM: ${NFS_MOUNT_POINT}"
else
  collect_error "NFS mount failed inside VM — check NAS NFS export allows non-privileged ports"
  exit 1
fi
```

Add the following immediately after:

```bash
# ---------------------------------------------------------------------------
# Section 2c: NFS watchdog timer inside Podman VM
# ---------------------------------------------------------------------------

set_section "VM-Internal NFS Watchdog"

log "Deploying NFS watchdog timer inside Podman VM..."

# Write the watchdog service unit
sudo -iu "${OPERATOR_USERNAME}" podman machine ssh transmission-vm -- \
  "sudo tee '/etc/systemd/system/nfs-watchdog.service' > /dev/null" <<'WATCHDOG_SVC'
[Unit]
Description=NFS mount health watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nfs-watchdog.sh
WATCHDOG_SVC

# Write the watchdog timer unit
sudo -iu "${OPERATOR_USERNAME}" podman machine ssh transmission-vm -- \
  "sudo tee '/etc/systemd/system/nfs-watchdog.timer' > /dev/null" <<'WATCHDOG_TMR'
[Unit]
Description=Run NFS mount health check every 2 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=120

[Install]
WantedBy=timers.target
WATCHDOG_TMR

# Write the watchdog script itself
# NFS_MOUNT_POINT and MOUNT_UNIT_NAME are expanded at deploy time;
# everything else is escaped into the script
sudo -iu "${OPERATOR_USERNAME}" podman machine ssh transmission-vm -- \
  "sudo tee '/usr/local/bin/nfs-watchdog.sh' > /dev/null" <<WATCHDOG_SCRIPT
#!/usr/bin/env bash
set -u
# nfs-watchdog.sh — Detect and recover stale NFS mounts inside the Podman VM.
# Deployed by podman-transmission-setup.sh; runs via nfs-watchdog.timer.

MOUNT_POINT="${NFS_MOUNT_POINT}"
MOUNT_UNIT="${MOUNT_UNIT_NAME}"

# Two failure modes to detect:
# 1. Stale/hung mount: stat hangs (NAS disappeared while mounted)
# 2. Not mounted: mount unit failed/timed out, leaving an empty directory
if timeout 5 stat "\${MOUNT_POINT}" >/dev/null 2>&1 \
   && mountpoint -q "\${MOUNT_POINT}"; then
    exit 0
fi

if mountpoint -q "\${MOUNT_POINT}"; then
    echo "NFS mount \${MOUNT_POINT} is stale — attempting recovery"
else
    echo "NFS mount \${MOUNT_POINT} is not mounted — attempting recovery"
fi

# Lazy unmount to release the stuck mount without blocking
umount -l "\${MOUNT_POINT}" 2>/dev/null || true

# Brief pause for unmount to take effect
sleep 2

# Remount via the systemd mount unit
systemctl start "\${MOUNT_UNIT}"

# Verify recovery (must check mountpoint, not just stat — empty dir fools stat)
if timeout 10 stat "\${MOUNT_POINT}" >/dev/null 2>&1 \
   && mountpoint -q "\${MOUNT_POINT}"; then
    echo "NFS mount recovered successfully"
else
    echo "NFS mount recovery failed — NAS may be offline"
    exit 1
fi
WATCHDOG_SCRIPT

sudo -iu "${OPERATOR_USERNAME}" podman machine ssh transmission-vm -- \
  "sudo chmod 755 /usr/local/bin/nfs-watchdog.sh"

# Enable the timer (daemon-reload already happened, but reload again for new units)
sudo -iu "${OPERATOR_USERNAME}" podman machine ssh transmission-vm -- \
  "sudo systemctl daemon-reload && sudo systemctl enable --now nfs-watchdog.timer"

# Verify timer is active
if sudo -iu "${OPERATOR_USERNAME}" podman machine ssh transmission-vm -- \
  "systemctl is-active nfs-watchdog.timer" | grep -q "active"; then
  log "✅ NFS watchdog timer active inside VM (checks every 2 minutes)"
else
  collect_warning "NFS watchdog timer failed to activate — manual check recommended"
fi
```

### Step 2: Verify the edit compiles

Run: `bash -n app-setup/podman-transmission-setup.sh`
Expected: No output (clean syntax)

### Step 3: Commit

```bash
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(podman-transmission): add NFS watchdog timer inside VM"
```

---

## Task 2: Add Podman health check to the container run command

**Files:**

- Modify: `app-setup/podman-transmission-setup.sh:726-758` (Section 11 podman run)
- Modify: `app-setup/podman-transmission-setup.sh:558-590` (Section 8 podman-machine-start.sh wrapper)

There are two `podman run` invocations — the one-time run in Section 11 (setup script) and the login-time run baked into `podman-machine-start.sh` (Section 8). Both need the health check flags.

### Step 1: Add health check flags to the Section 11 `podman run` (lines 726-758)

Find this line inside the `podman run` block:

```bash
    --restart unless-stopped \
```

Add the following health check flags immediately after it:

```bash
    --health-cmd "curl -sf --max-time 5 http://localhost:9091/transmission/rpc/ || exit 1" \
    --health-interval 60s \
    --health-start-period 120s \
    --health-retries 3 \
    --health-on-failure restart \
```

### Step 2: Add health check flags to the Section 8 `podman-machine-start.sh` wrapper (lines 558-590)

Find this line inside the wrapper's `podman run` block:

```bash
    --restart unless-stopped \\
```

Add the following health check flags immediately after it (note double backslashes for the heredoc):

```bash
    --health-cmd "curl -sf --max-time 5 http://localhost:9091/transmission/rpc/ || exit 1" \\
    --health-interval 60s \\
    --health-start-period 120s \\
    --health-retries 3 \\
    --health-on-failure restart \\
```

### Step 3: Verify syntax

Run: `bash -n app-setup/podman-transmission-setup.sh`
Expected: No output (clean syntax)

### Step 4: Commit

```bash
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(podman-transmission): add health check with auto-restart on failure"
```

---

## Task 3: Deploy to the running server

This task deploys the new units to the live `transmission-vm` without re-running the full setup script.

### Step 1: Deploy the NFS watchdog into the VM

```bash
# Write the watchdog script
sudo -u operator -i bash -c 'podman machine ssh transmission-vm -- \
  "sudo tee /usr/local/bin/nfs-watchdog.sh > /dev/null" <<'\''SCRIPT'\''
#!/usr/bin/env bash
set -u
MOUNT_POINT="/var/mnt/DSMedia"
MOUNT_UNIT="var-mnt-DSMedia.mount"
# Both checks required: stat detects stale/hung mounts, mountpoint detects unmounted dirs
if timeout 5 stat "${MOUNT_POINT}" >/dev/null 2>&1 \
   && mountpoint -q "${MOUNT_POINT}"; then
    exit 0
fi
if mountpoint -q "${MOUNT_POINT}"; then
    echo "NFS mount ${MOUNT_POINT} is stale — attempting recovery"
else
    echo "NFS mount ${MOUNT_POINT} is not mounted — attempting recovery"
fi
umount -l "${MOUNT_POINT}" 2>/dev/null || true
sleep 2
systemctl start "${MOUNT_UNIT}"
if timeout 10 stat "${MOUNT_POINT}" >/dev/null 2>&1 \
   && mountpoint -q "${MOUNT_POINT}"; then
    echo "NFS mount recovered successfully"
else
    echo "NFS mount recovery failed — NAS may be offline"
fi
SCRIPT'
```

```bash
# Make executable
sudo -u operator -i bash -c 'podman machine ssh transmission-vm -- \
  "sudo chmod 755 /usr/local/bin/nfs-watchdog.sh"'
```

```bash
# Write the service unit
sudo -u operator -i bash -c 'podman machine ssh transmission-vm -- \
  "sudo tee /etc/systemd/system/nfs-watchdog.service > /dev/null" <<'\''UNIT'\''
[Unit]
Description=NFS mount health watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nfs-watchdog.sh
UNIT'
```

```bash
# Write the timer unit
sudo -u operator -i bash -c 'podman machine ssh transmission-vm -- \
  "sudo tee /etc/systemd/system/nfs-watchdog.timer > /dev/null" <<'\''UNIT'\''
[Unit]
Description=Run NFS mount health check every 2 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=120

[Install]
WantedBy=timers.target
UNIT'
```

```bash
# Enable and start
sudo -u operator -i bash -c 'podman machine ssh transmission-vm -- \
  "sudo systemctl daemon-reload && sudo systemctl enable --now nfs-watchdog.timer"'
```

### Step 2: Verify the watchdog timer is active

Run: `sudo -u operator -i bash -c 'podman machine ssh transmission-vm -- "systemctl list-timers nfs-watchdog.timer"'`
Expected: Timer listed with next activation time

### Step 3: Test the watchdog script manually

Run: `sudo -u operator -i bash -c 'podman machine ssh transmission-vm -- "sudo /usr/local/bin/nfs-watchdog.sh; echo exit=\$?"'`
Expected: exit=0 (mount is healthy, script exits immediately)

### Step 4: Recreate the container with health check flags

```bash
sudo -u operator -i bash -c 'podman stop transmission-vpn && podman rm transmission-vpn'
```

Then start it with health check flags using the same env/volume config as the existing container, plus the new flags. The exact command depends on the deployed `podman-machine-start.sh` — the simplest approach is to update that script in place and run it:

```bash
# Read current script, add health check flags after --restart line, write back
sudo -u operator -i bash -c '
  SCRIPT="$HOME/.local/bin/podman-machine-start.sh"
  if grep -q "health-cmd" "${SCRIPT}"; then
    echo "Health check already present"
  else
    sed -i.bak "/--restart unless-stopped/a\\
    --health-cmd \"curl -sf --max-time 5 http://localhost:9091/transmission/rpc/ || exit 1\" \\\\\\
    --health-interval 60s \\\\\\
    --health-start-period 120s \\\\\\
    --health-retries 3 \\\\\\
    --health-on-failure restart \\\\" "${SCRIPT}"
    echo "Health check flags added"
  fi
'
```

Then run the startup script:

```bash
sudo -u operator -i bash -c 'bash ~/.local/bin/podman-machine-start.sh'
```

### Step 5: Verify health check is configured

Run: `sudo -u operator -i bash -c 'podman inspect transmission-vpn --format "{{.Config.Healthcheck}}"'`
Expected: Shows the curl health check command

### Step 6: Wait ~2 minutes and verify health status

Run: `sudo -u operator -i bash -c 'podman inspect transmission-vpn --format "{{.State.Health.Status}}"'`
Expected: `healthy`

### Step 7: Verify Transmission web UI

Run: `curl -s -o /dev/null -w "%{http_code}" --max-time 5 -k https://localhost/transmission/web/`
Expected: `200`
