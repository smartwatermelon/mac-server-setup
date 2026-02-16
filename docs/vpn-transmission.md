# Transmission VPN Protection — Staged Architecture

This document describes the multi-layered VPN protection system for Transmission on the Mac Mini server. Each stage is independently valuable, verifiable, and reversible.

---

## Problem

PIA's split-tunnel "Only VPN for Transmission" frequently forgets its configuration, causing Transmission to torrent over the home IP (privacy leak). There was zero kernel-level enforcement — if PIA misbehaved, Transmission leaked silently.

## Solution: Defense in Depth

| Stage | Layer | Protection | Status |
|-------|-------|------------|--------|
| 1 | PIA configuration | Invert split-tunnel default | Deployed |
| 1.5 | PIA config watchdog | Detect and restore split tunnel drift | Deployed |
| 2 | VPN monitor script | Detect VPN drops, pause torrents, manage bind-address | Deployed |
| 3 | PF verification | Confirm kernel filtering works | **FAILED** (macOS 26.3) |
| 3b | PF route-to bypass | Plex VPN bypass via PF + public IP monitor | Deployed |
| 4 | PF kill-switch | Kernel-level traffic blocking per user | Not viable |
| 5 | Automated updates | Homebrew, MAS, macOS updates on schedule | Deployed |

**Production architecture is Stages 1+1.5+2+3b.** Stage 3 confirmed that PF `user`-based filtering does not enforce on macOS 26.3, so Stage 4 (kernel-level kill-switch) is not viable. Stage 3b uses a different PF mechanism (`route-to`) that works despite Stage 3's failure.

## Stage 1: PIA Split-Tunnel Inversion

**Status:** Deployed (2026-02-12)

### The Inversion

Instead of "Only VPN for Transmission" (which PIA forgets), use "Bypass VPN" for everything else:

1. PIA → Settings → Split Tunnel
2. Mode: **Bypass VPN**
3. Add bypass entries: Plex, sshd, web browsers
4. Enable **Advanced Kill Switch**

**Why this works:** Default traffic now goes through VPN (including Transmission). If PIA "forgets" the bypass list, Plex gets slow but Transmission stays protected.

### Manual Bind-Address (Quick Fix)

```bash
# SSH as operator@tilsit.local
VPN_IP=$(ifconfig | grep -A1 'utun' | grep 'inet ' | awk '{print $2}' | head -1)
defaults write org.m0k.transmission BindAddressIPv4 -string "${VPN_IP}"
osascript -e 'quit app "Transmission"' && sleep 2 && open -a Transmission
```

This is temporary — Stage 2 automates it.

### Rollback

Revert PIA split tunnel to "Only VPN" mode.

---

## Stage 1.5: PIA Config Watchdog

**Status:** Deployed (2026-02-13) via `pia-split-tunnel-monitor.sh` LaunchAgent

### Config Drift Problem

PIA frequently "forgets" its split tunnel configuration. With the Stage 1 inversion architecture, forgetting means all traffic goes through VPN — including Plex, which is unusable through a multi-hop overseas VPN connection. The VPN monitor (Stage 2) handles VPN drops but not PIA config drift.

### Stage 1.5 Behavior

The PIA monitor polls `/Library/Preferences/com.privateinternetaccess.vpn/settings.json` every 60 seconds and compares monitored fields against a saved reference:

- **Config matches:** No action (normal state)
- **Drift detected:** Restores config via `piactl -u applysettings`, reconnects PIA, verifies fix
- **Fix fails 3 times:** Backs off for 5 minutes, then retries

Monitored fields: `splitTunnelEnabled`, `splitTunnelRules`, `killswitch`, `bypassSubnets`.

### Stage 1.5 Files

| File | Purpose |
|------|---------|
| `~operator/.local/bin/pia-split-tunnel-monitor.sh` | Monitor script (deployed from template) |
| `~operator/.local/etc/pia-split-tunnel-reference.json` | Reference config (saved during deployment) |
| `~/Library/LaunchAgents/com.tilsit.pia-monitor.plist` | LaunchAgent (RunAtLoad, KeepAlive) |
| `~operator/.local/state/tilsit-pia-monitor.log` | Monitor log |

### Stage 1.5 Deployment

Deployed automatically by `transmission-setup.sh` from the template at `app-setup/templates/pia-split-tunnel-monitor.sh`. The deployment saves the current PIA split tunnel config as the reference.

To update the reference after intentionally changing PIA settings:

```bash
~/.local/bin/pia-split-tunnel-monitor.sh --save-reference
```

### Stage 1.5 Verification

```bash
# Check monitor is running
launchctl list | grep pia-monitor

# Watch the log
tail -f ~/.local/state/tilsit-pia-monitor.log

# Check reference file
cat ~/.local/etc/pia-split-tunnel-reference.json

# Test: via PIA GUI, uncheck split tunnel or remove an app
# Monitor should detect within 60s, restore config, reconnect, notify
```

### Changing PIA Settings

When intentionally changing PIA settings (adding or removing bypass apps, changing subnets), the monitor will detect the change as drift and revert it within 60 seconds. Use the pause-file workflow to make changes safely:

```bash
# 1. Pause the monitor (it keeps running, just stops reverting)
touch ~/.local/etc/pia-monitor-paused

# 2. Make changes in PIA GUI (add/remove bypass apps, change settings)

# 3. Save new reference and unpause in one step
~/.local/bin/pia-split-tunnel-monitor.sh --save-reference
# --save-reference also removes the pause file automatically
```

While paused, the monitor still logs drift detection but does not auto-restore. This gives you time to make changes and verify them before saving the new reference.

**Warning:** If you unpause without running `--save-reference`, the monitor resumes with the old reference and will revert your changes on the next cycle.

### Stage 1.5 Rollback

```bash
launchctl unload ~/Library/LaunchAgents/com.tilsit.pia-monitor.plist
```

---

## Stage 2: VPN Monitor Script

**Status:** Deployed (2026-02-12) via `vpn-monitor.sh` LaunchAgent

### How It Works

The VPN monitor polls `utun0-utun15` every 5 seconds:

- **VPN UP:** Ensures Transmission is running with VPN IP as bind-address
- **VPN IP CHANGE:** Updates bind-address, restarts Transmission
- **VPN DROP:** Kills Transmission (zero network activity guaranteed)
- **VPN RESTORE:** Updates bind-address, relaunches Transmission

Kill-and-restart is more reliable than RPC pause/resume: a dead process cannot leak traffic (no DHT, PEX, or tracker announces). Transmission persists torrent state in its resume files, so previously-active torrents resume on relaunch and paused ones stay paused.

### Files

| File | Purpose |
|------|---------|
| `~operator/.local/bin/vpn-monitor.sh` | Monitor script (deployed from template) |
| `~/Library/LaunchAgents/com.tilsit.vpn-monitor.plist` | LaunchAgent (RunAtLoad, KeepAlive) |
| `~operator/.local/state/tilsit-vpn-monitor.log` | Monitor log |

### Deployment

Deployed automatically by `transmission-setup.sh` from the template at `app-setup/templates/vpn-monitor.sh`.

### Verification

```bash
# Check monitor is running
launchctl list | grep vpn-monitor

# Watch the log
tail -f ~/.local/state/tilsit-vpn-monitor.log

# Test: disconnect VPN briefly via PIA GUI
# Monitor should: detect drop -> kill Transmission -> set bind 127.0.0.1 -> notify

# Test: reconnect VPN
# Monitor should: detect IP -> set bind-address -> relaunch Transmission -> notify
```

### Stage 2 Rollback

```bash
launchctl unload ~/Library/LaunchAgents/com.tilsit.vpn-monitor.plist
```

---

## Stage 3: PF User Keyword Verification

**Status:** FAILED on macOS 26.3 (2026-02-12)

### Purpose

Verify that macOS PF (Packet Filter) supports the `user` keyword for per-user traffic filtering. This is the go/no-go gate for Stage 4.

### Running the Test

```bash
# On the target server (NOT dev machine)
sudo ./scripts/server/pf-test-user.sh
```

The script:

1. Creates a throwaway `_pftest` user (UID 299)
2. Loads a PF rule blocking `_pftest` on `en0`
3. Tests that `_pftest` is blocked and other users are not
4. Cleans up completely (user, rules, PF state)

### Result (macOS 26.3)

**VERDICT: FAIL.** PF loaded the rule syntactically (including `user = 299`) but did not enforce traffic filtering. The `_pftest` user was able to reach the internet despite the block rule. Stage 4 is not viable on this macOS version.

The `user` keyword is documented in pf.conf(5) and the rule parses correctly, but the kernel does not enforce it. This may be a regression or intentional change in macOS 26.x.

---

## Stage 3b: Plex VPN Bypass (PF route-to)

**Status:** Deployed (2026-02-16) via `plex-vpn-bypass.sh` LaunchDaemon

### PIA Transparent Proxy Failure

PIA's macOS split tunnel transparent proxy is fundamentally broken. The proxy intercepts bypass-app traffic and binds outbound sockets to the physical IP, but data forwarding fails with `ioOnClosedChannel` and `Empty buffer` errors for all bypass apps. Every proxied session closes with zero bytes transferred. This affects both OpenVPN and WireGuard protocols.

See `docs/pia-split-tunnel-bug.md` for full bug documentation with proxy log excerpts.

### Solution

PF `route-to` rules loaded into a custom anchor force traffic from the physical IP through the physical interface at the kernel level, bypassing PIA's broken userspace proxy entirely. A companion daemon monitors the public IP and updates Plex's `customConnections` setting when it changes.

```text
table <rfc1918> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 }
pass in quick on en0 proto tcp to port 32400
pass out quick route-to (en0 10.0.15.1) from 10.0.15.15 to ! <rfc1918>
```

**How it works:**

- `pass in` — allows external clients to reach Plex on port 32400 via the physical interface
- `pass out route-to` — forces outbound traffic from the physical IP through the physical gateway instead of the VPN tunnel, so Plex can reach plex.tv for authentication and serve remote clients

The rules are loaded into anchor `com.apple/100.<hostname>.vpn-bypass`. The script auto-detects the physical interface, IP, and gateway at runtime (not hardcoded).

### Why This Works Despite Stage 3 Failure

Stage 3 tested PF's `user` keyword for per-user filtering (blocking traffic by UID). That failed because macOS 26.3 does not enforce user-based PF rules. Stage 3b uses a completely different PF mechanism: `route-to` for policy-based routing. This is a routing directive, not a filter, and it works on macOS 26.3.

### Stage 3b Files

| File | Purpose |
|------|---------|
| `/usr/local/bin/plex-vpn-bypass.sh` | Daemon script (deployed from template) |
| `/Library/LaunchDaemons/com.<hostname>.plex-vpn-bypass.plist` | LaunchDaemon (RunAtLoad, KeepAlive, runs as root) |
| `/var/log/<hostname>-plex-vpn-bypass.log` | Daemon log |

### Stage 3b Behavior

The daemon polls every 60 seconds:

1. **Ensure PF rules** — check anchor, reload if missing or network config changed
2. **Check public IP** — `curl --interface <physical_ip> checkip.amazonaws.com`
3. **If IP changed** — update Plex `customConnections` via local API, log, notify

### Stage 3b Deployment

Deployed by `transmission-setup.sh` from the template at `app-setup/templates/plex-vpn-bypass.sh`. The deployment creates a root-level LaunchDaemon (PF operations require root).

### Stage 3b Verification

```bash
# Check daemon is running
sudo launchctl list | grep plex-vpn-bypass

# Verify PF rules are loaded
sudo pfctl -a 'com.apple/100.tilsit.vpn-bypass' -sr

# Verify bypass works (should return home IP, not VPN IP)
curl --interface 10.0.15.15 http://checkip.amazonaws.com

# Watch the log
tail -f /var/log/tilsit-plex-vpn-bypass.log

# Test: change IP (disconnect/reconnect router)
# Daemon should detect within 60s and update Plex customConnections
```

### Stage 3b Rollback

```bash
sudo launchctl unload /Library/LaunchDaemons/com.tilsit.plex-vpn-bypass.plist
sudo pfctl -a 'com.apple/100.tilsit.vpn-bypass' -F rules
```

---

## Stage 4: Kernel-Level Kill-Switch (Not Viable)

**Status:** Not viable — Stage 3 FAILED on macOS 26.3

The scripts and PF rules remain in the repo in case future macOS versions restore PF `user` enforcement. To re-evaluate, re-run Stage 3 after a macOS update.

Prerequisites (all must be true):

- Stage 3 PASSED
- Stages 1-2 are stable and proven
- You want the additional kernel-level protection

### Architecture

```text
                    ┌─────────────────┐
                    │  PF Firewall    │
                    │  (kernel level) │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
         en0 (block)    utun* (allow)   lo0 (allow)
              │              │              │
              ×         ┌────┴────┐    ┌────┴────┐
         (dropped)      │ VPN     │    │ RPC API │
                        │ tunnel  │    │ Plex    │
                        └────┬────┘    └─────────┘
                             │
                    ┌────────┴────────┐
                    │  transmission-  │
                    │  daemon         │
                    │  (_transmission)│
                    └─────────────────┘
```

### Components

| Component | File | Purpose |
|-----------|------|---------|
| System user | `_transmission` (via dscl) | Dedicated daemon user |
| PF rules | `/etc/pf.anchors/transmission-killswitch` | Block `_transmission` on en0/en1, allow on utun*/lo0 |
| PF loader | `/Library/LaunchDaemons/com.tilsit.pf-killswitch.plist` | Load PF rules at boot |
| NAS mount | `/Library/LaunchDaemons/com.tilsit.mount-nas-transmission.plist` | System-level NAS mount for daemon |
| Daemon | `/Library/LaunchDaemons/com.tilsit.transmission-daemon.plist` | Runs as `_transmission`, waits for NAS + PF |
| Config | `/var/lib/transmission/.config/transmission-daemon/settings.json` | Daemon configuration |

### Stage 4 Deployment

```bash
# On the target server
sudo ./scripts/server/setup-vpn-killswitch.sh
```

### Stage 4 Verification

```bash
# 1. Daemon running as correct user
ps aux | grep transmission-daemon  # should show _transmission

# 2. PF blocking on physical interface
sudo -u _transmission curl --interface en0 --max-time 5 https://ifconfig.me  # should timeout

# 3. Traffic going through VPN
sudo -u _transmission curl --max-time 5 https://ifconfig.me  # should show VPN IP

# 4. Web UI accessible
curl http://tilsit.local:19091  # should respond

# 5. Reboot test
sudo reboot  # all services should recover
```

### Plist-to-settings.json Key Mapping

These are the critical translations from Transmission.app plist keys to daemon `settings.json` keys:

| Plist Key (GUI) | settings.json Key (Daemon) | Value |
|-----------------|---------------------------|-------|
| `BindPort` | `peer-port` | 40944 |
| `RPCPort` | `rpc-port` | 19091 |
| `RPCUsername` | `rpc-username` | tilsit |
| `RPCPassword` | `rpc-password` | tilsit |
| `DownloadFolder` | `download-dir` | /var/lib/transmission/mnt/... |
| `AutoImportDirectory` | `watch-dir` | ~/.local/sync/dropbox |
| `DoneScriptPath` | `script-torrent-done-filename` | path |
| `EncryptionRequire` | `encryption` | 2 (required) |
| `PeersTotal` | `peer-limit-global` | 2048 |
| `PeersTorrent` | `peer-limit-per-torrent` | 256 |

### Catch Integration (Daemon Mode)

When running as daemon, Catch cannot use magnet links (URL handler requires GUI). Instead:

1. Change `CATCH_USE_MAGNETS="false"` in config.conf
2. Update ShowRSS URL: change `magnets=true` to `magnets=false`
3. Catch downloads `.torrent` files to the watch directory
4. transmission-daemon picks them up automatically

### Stage 4 Rollback

```bash
sudo launchctl unload /Library/LaunchDaemons/com.tilsit.transmission-daemon.plist
sudo launchctl unload /Library/LaunchDaemons/com.tilsit.pf-killswitch.plist
sudo launchctl unload /Library/LaunchDaemons/com.tilsit.mount-nas-transmission.plist
sudo pfctl -a "transmission-killswitch" -F rules
# Re-enable operator's Transmission.app LaunchAgent
launchctl load ~/Library/LaunchAgents/com.tilsit.transmission.plist
open -a Transmission
```

---

## Stage 5: Automated Updates (Independent)

**Status:** Deployed (2026-02-12) via `setup-auto-updates.sh`

| Update Type | Schedule | Method | Scope |
|-------------|----------|--------|-------|
| Homebrew | Daily 04:30 | `brew upgrade` LaunchDaemon (as admin) | Formulae + casks |
| Mac App Store | Automatic | macOS built-in auto-update | App Store apps |
| macOS | Sundays 04:00 | `softwareupdate --download` LaunchDaemon | OS updates (download-only) |

Homebrew uses a LaunchDaemon (not LaunchAgent) with `UserName` set to the administrator — LaunchAgents only run when the user has a GUI session, and the administrator is rarely logged in on the desktop. macOS Software Update downloads only — no auto-install, no surprise reboots.

### Stage 5 Deployment

```bash
# On the target server (as administrator)
./scripts/server/setup-auto-updates.sh
```

### Stage 5 Verification

```bash
sudo launchctl list | grep brew-upgrade
defaults read /Library/Preferences/com.apple.commerce AutoUpdate
sudo launchctl list | grep softwareupdate
# Check logs after 24h
cat ~/.local/state/tilsit-brew-upgrade.log
```

---

## Current Architecture (Post-Deployment)

**Active protection: Stages 1+1.5+2+3b.** Stage 3 failed (PF `user` keyword), so Stage 4 is not available. Stage 3b uses a different PF mechanism (`route-to`) that works despite Stage 3's failure.

- **Stage 1** inverts the failure mode: if PIA forgets its config, Plex gets slow but Transmission stays on VPN
- **Stage 1.5** enforces Stage 1: if PIA forgets its split tunnel config, the watchdog detects it within 60 seconds and auto-restores from a saved reference
- **Stage 2** automates recovery: VPN drops are detected within 5 seconds, torrents are paused, and bind-address is locked to loopback until VPN returns
- **Stage 3b** bypasses PIA's broken split tunnel proxy: PF `route-to` rules force Plex traffic through the physical interface, and the daemon monitors the public IP to keep Plex's `customConnections` current
- **Stage 5** keeps the system updated without manual intervention

To re-evaluate Stage 4: re-run `pf-test-user.sh` after a macOS update. If PF `user` enforcement is restored, the kill-switch scripts are ready to deploy.

---

## Log Locations

| Log | Path |
|-----|------|
| PIA monitor | `~operator/.local/state/tilsit-pia-monitor.log` |
| VPN monitor | `~operator/.local/state/tilsit-vpn-monitor.log` |
| Plex VPN bypass | `/var/log/tilsit-plex-vpn-bypass.log` |
| Brew upgrade | `~admin/.local/state/tilsit-brew-upgrade.log` |
| Software update | `/var/log/tilsit-softwareupdate.log` |
