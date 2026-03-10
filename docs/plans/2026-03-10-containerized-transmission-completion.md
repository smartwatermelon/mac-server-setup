# Containerized Transmission — Completion Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete the remaining setup, validation, and Phase 2 cutover for the containerized Transmission stack.

**Architecture:** haugene/transmission-openvpn in a rootful Podman machine (`transmission-vm`), VPN-enforced at the container level. Phase 1 runs in parallel on port 9092; Phase 2 cuts over to 9091 and retires the native Transmission.app stack.

**Context:** Phase 1 deployed 2026-03-10. Container running, VPN verified (PIA Panama), test torrent to NAS confirmed. Two features were added post-deployment (blocklist, magnet handler) but not yet fully applied to the running server.

---

## Task 1: Merge the pending branch

**Files:**

- Branch: `claude/feature-blocklist-magnet-handler-<timestamp>` (2 commits: blocklist+magnet handler feat, awk session ID fix)

**Step 1: Push and create PR**

```bash
git push -u origin claude/feature-blocklist-magnet-handler-<timestamp>
gh pr create --title "feat(podman-transmission): IP blocklist, magnet handler, awk session ID fix" \
  --body "..."
```

**Step 2: Confirm CI passes, merge**

Follow Protocol 6 — create PR, wait for CI, merge on explicit approval.

---

## Task 2: Clean up TILSIT and apply blocklist config

**Context:** The running container was started with the old `compose.yml` (no blocklist env vars). The updated `compose.yml` is in the repo but not yet on TILSIT.

**Step 1: Remove the Debian test torrent**

In browser: `http://tilsit.local:9092/transmission/web/` → select debian torrent → Remove (delete local data too, nothing was downloaded).

**Step 2: rsync updated compose.yml to TILSIT**

```bash
# On dev Mac, from repo root:
rsync -av app-setup/containers/transmission/compose.yml \
  operator@tilsit.local:~/containers/transmission/compose.yml
```

Wait — this is the template file with `__PLACEHOLDERS__`. The deployed file on TILSIT already has substituted values. **Do NOT rsync the template directly.**

Instead, SSH in and add the two env vars manually to the already-deployed `compose.yml`:

```bash
ssh operator@tilsit.local
# Edit ~/containers/transmission/compose.yml
# Add these two lines after TRANSMISSION_ENCRYPTION=2:
#   - TRANSMISSION_BLOCKLIST_ENABLED=true
#   - TRANSMISSION_BLOCKLIST_URL=https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz
```

**Step 3: Restart the container stack to pick up new env vars**

```bash
ssh operator@tilsit.local
podman compose -f ~/containers/transmission/compose.yml \
  --env-file ~/containers/transmission/.env down
podman compose -f ~/containers/transmission/compose.yml \
  --env-file ~/containers/transmission/.env up -d
# Verify blocklist loaded:
podman logs transmission-vpn 2>&1 | grep -i blocklist
```

**Step 4: Verify container is back up**

```bash
podman exec transmission-vpn curl -s ifconfig.io  # should return PIA exit IP
# Web UI: http://tilsit.local:9092/transmission/web/
```

---

## Task 3: Complete the macOS magnet link handler

**Context:** `transmission-add-magnet.sh` is deployed and working. The AppleScript app (`TransmissionMagnetHandler.app`) has not been compiled on TILSIT. The current `defaults LSHandlers` entry still points to `org.m0k.transmission`.

**Recommended approach:** Re-run `podman-transmission-setup.sh --force` from the `app-setup/` directory on TILSIT. It is fully idempotent — it will skip the running container (Section 11 only starts if no errors), recompile the app, and re-register the handler.

```bash
ssh operator@tilsit.local
cd ~/setup/app-setup   # or wherever the setup package landed
./podman-transmission-setup.sh --force
```

**If setup package is not available on TILSIT**, do it manually:

```bash
ssh operator@tilsit.local
```

```applescript
# Write AppleScript source
cat > /tmp/magnet-handler.applescript <<'EOF'
on open location this_URL
    do shell script "/Users/operator/.local/bin/transmission-add-magnet.sh " & quoted form of this_URL
end open location
EOF
```

```bash
BUNDLE_ID="com.tilsit.transmission-magnet-handler"
APP="${HOME}/Applications/TransmissionMagnetHandler.app"
mkdir -p ~/Applications
osacompile -o "${APP}" /tmp/magnet-handler.applescript
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "${APP}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "${APP}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "${APP}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string magnet" "${APP}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string 'BitTorrent Magnet Link'" "${APP}/Contents/Info.plist" 2>/dev/null || true
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"${LSREGISTER}" -f "${APP}"
defaults write com.apple.LaunchServices/com.apple.launchservices.secure \
  LSHandlers -array-add '{
    LSHandlerURLScheme = "magnet";
    LSHandlerRoleAll = "com.tilsit.transmission-magnet-handler";
    LSHandlerPreferredVersions = {
        LSHandlerRoleAll = "-";
    };
}'
```

**Step to verify:** Click a magnet link in Safari or open one from Terminal:

```bash
open "magnet:?xt=urn:btih:86d0b154b81ba13fdbc6f4fba11c56b2c06bbf30&dn=test"
# Should trigger a macOS notification "Magnet link added to Transmission"
# and torrent should appear in http://tilsit.local:9092/transmission/web/
```

---

## Task 4: Phase 1 kill switch test

**Goal:** Confirm that when the VPN drops, Transmission has zero network activity (the container's network is enforced at the kernel level by gluetun).

**Step 1: Note current download activity**

In the web UI, start a well-seeded public torrent so there's active traffic.

**Step 2: Force VPN disconnect from TILSIT**

```bash
ssh andrewrich@tilsit.local  # as administrator
piactl disconnect
```

**Step 3: Verify Transmission traffic stops**

In the web UI, download rate should drop to 0 immediately. The container should still be running (the kill switch is inside gluetun, not a process kill).

**Step 4: Reconnect and confirm recovery**

```bash
piactl connect
# Wait ~10s, then check:
ssh operator@tilsit.local
podman exec transmission-vpn curl -s ifconfig.io  # should return PIA IP again
# Transmission should resume downloading
```

**Expected result:** Traffic stops on VPN drop, resumes on reconnect, without any intervention.

---

## Task 5: Verify PIA port forwarding

**Goal:** Confirm the forwarded port from PIA matches the peer port Transmission is advertising. This allows peers to initiate connections to us (better download speeds).

**Step 1: Check container logs for forwarded port**

```bash
ssh operator@tilsit.local
podman logs transmission-vpn 2>&1 | grep -i "port\|forward" | tail -20
```

**Step 2: Check Transmission peer port setting**

In the web UI: Edit → Preferences → Network → "Peer listening port". This value should match the forwarded port from Step 1.

**Step 3: Test port is open**

From outside the LAN (or via a port-check service), verify the port is reachable at the server's public IP.

---

## Task 6: Trigger-watcher end-to-end test

**Goal:** Confirm the full pipeline: torrent completes → `transmission-post-done.sh` fires inside container → `.done` signal written to NAS → `transmission-trigger-watcher.sh` picks it up on macOS → FileBot renames and moves the file.

**Step 1: Add a small well-seeded test torrent**

Use a small public domain file (e.g., a CC-licensed short film or a small Linux ISO). Add via magnet or `.torrent` file to the watch directory.

**Step 2: Monitor the pipeline**

```bash
ssh operator@tilsit.local
# Container side:
podman logs -f transmission-vpn
# Watcher side:
tail -f ~/.local/state/tilsit-trigger-watcher-stdout.log
# NAS done directory:
ls ~/.local/mnt/DSMedia/Media/Torrents/done/
```

**Step 3: Confirm FileBot output**

Check `~/.local/mnt/DSMedia/Media/` for the renamed and moved file.

**Step 4: Clean up test file** from media library.

---

## Task 7: Phase 2 cutover (after ≥3 days Phase 1 stable)

**Prerequisites:** Tasks 1–6 complete, container stable for ≥3 days.

**Step 1: Update Caddy config (tilsit-caddy-v1 repo)**

Update any Caddy reverse proxy rules that reference port 9092 to point to 9091.

**Step 2: Update config.conf and re-run setup**

```bash
# On dev Mac:
# Edit config/config.conf: set TRANSMISSION_HOST_PORT=9091
# AirDrop updated package to TILSIT (or rsync app-setup/ directory)
ssh andrewrich@tilsit.local
cd ~/setup/app-setup
./podman-transmission-setup.sh --force
```

This redeploys `compose.yml` with port 9091, recreates the `podman-machine-start.sh` wrapper with the new port, redeploys `transmission-add-magnet.sh` with port 9091 baked in, and reregisters the magnet handler.

**Step 3: Restart container on new port**

```bash
ssh operator@tilsit.local
podman compose -f ~/containers/transmission/compose.yml \
  --env-file ~/containers/transmission/.env down
podman compose -f ~/containers/transmission/compose.yml \
  --env-file ~/containers/transmission/.env up -d
```

**Step 4: Decommission native Transmission**

```bash
ssh operator@tilsit.local
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.tilsit.transmission.plist
rm ~/Library/LaunchAgents/com.tilsit.transmission.plist
# Stop vpn-monitor (it managed the native process):
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.tilsit.vpn-monitor.plist
rm ~/Library/LaunchAgents/com.tilsit.vpn-monitor.plist
```

The VPN monitor is no longer needed — gluetun enforces the kill switch at the container level.

**Step 5: Update plan.md**

Mark Phase 1 complete, Phase 2 in progress, update Running Services table, remove vpn-monitor from services list.

---

## Quick Reference

| Item | Status |
|------|--------|
| Container running (VPN, NAS, web UI) | ✅ Done |
| Blocklist config in compose.yml (repo) | ✅ Done |
| Blocklist applied to running TILSIT container | ⬜ Task 2 |
| Magnet handler (script) | ✅ Done |
| Magnet handler (OS dispatch via app) | ⬜ Task 3 |
| Kill switch test | ⬜ Task 4 |
| Port forwarding verified | ⬜ Task 5 |
| Trigger-watcher end-to-end | ⬜ Task 6 |
| Phase 1 ≥3 days stable | ⬜ (waiting) |
| Phase 2 cutover to port 9091 | ⬜ Task 7 |
| Native Transmission decommissioned | ⬜ Task 7 |
