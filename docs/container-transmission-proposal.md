# Proposal: Containerized Transmission with gluetun VPN

**Status:** Active — approved for implementation 2026-03-08
**Decision:** haugene/transmission-openvpn (not gluetun + linuxserver/transmission)
  Rationale: single container, automatic PIA port forwarding, battle-tested.
  Server uses Panama PIA endpoint (non-US = port forwarding supported with OpenVPN).
**Date:** 2026-02-27
**Motivation:** Replace the current PIA Desktop + split tunnel + shell script monitoring stack with a
container-based architecture that provides kernel-level VPN enforcement and eliminates recurring
reliability problems.

---

## 1. Problem Statement

The current Transmission + VPN setup has required multiple debugging sessions and patches:

| Problem | Root Cause | Fix Applied |
|---------|-----------|-------------|
| Transmission on wrong IP after VPN restart | `launch_transmission` failure → `set -e` crash-loop | `\|\| log "WARNING"` guards (PR #75) |
| PIA consent dialog ignored for 90+ minutes | `StartInterval` job exits in ~3s → launchd throttle escalation | Converted to daemon (PR #75) |
| Split tunnel loses consent after reboot | NETransparentProxy loses signature at boot | pia-proxy-consent auto-clicker daemon |
| Transmission briefly unguarded on monitor restart | KeepAlive restarts vpn-monitor before kill completes | Mitigated by PR #75, not eliminated |

These are symptoms of the same underlying architecture mismatch: enforcing VPN-only networking at
the **application layer** (a shell script that polls every 5 seconds and kills a process) is
inherently racy. The consent dialog problem exists because macOS's split tunnel mechanism
(NETransparentProxy) is designed for interactive use, not unattended servers.

---

## 2. Proposed Architecture

> **Note:** The original proposal (§§3, 6) described gluetun + linuxserver/transmission on OrbStack.
> After review, the decision changed to **haugene/transmission-openvpn on Podman** — a single
> container that bundles OpenVPN, Transmission, and PIA port forwarding. See the Decision line
> at the top of this document. The architecture below reflects the implemented design.

Replace the entire PIA Desktop + split tunnel + monitoring stack with:

```text
┌─────────────────────────────────────────────────────────────┐
│  Podman (rootful machine: transmission-vm)                   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  haugene/transmission-openvpn container               │   │
│  │  • OpenVPN client (PIA, Panama endpoint)             │   │
│  │  • iptables kill switch: blocks all non-VPN traffic  │   │
│  │  • PIA port forwarding (built-in to haugene)         │   │
│  │  • Transmission + web UI at port 9091                │   │
│  │  • Bind mount: NAS at /data                          │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

macOS host
  • Plex.app — unaffected, uses regular internet directly
  • rclone, FileBot, Catch — unaffected
  • NAS NFS mount — used by Plex, FileBot, and Finder
  • trigger-watcher LaunchAgent — bridges container done-events to FileBot
```

### How the kill switch works

Transmission runs in gluetun's network namespace. The Linux kernel's routing table in that
namespace has exactly one default route: the WireGuard tunnel interface. iptables rules added by
gluetun drop all non-tunnel traffic. If the WireGuard tunnel drops, Transmission's packets are
dropped at the kernel level — not by a polling script, not after a 5-second detection window.
There is no race condition and no "unguarded window."

---

## 3. Components

> **Note:** The original proposal evaluated gluetun + linuxserver/transmission on OrbStack.
> The decision changed to haugene/transmission-openvpn on Podman. This section describes
> the implemented components.

### 3.1 Podman

[Podman](https://podman.io) is the container runtime. Chosen over OrbStack because:

- CLI formula (Homebrew) — scriptable and headless-friendly
- No GUI dependency (`orbstack` is a Cask, harder to automate)
- Rootful machine mode (`podman machine init --rootful`) provides `CAP_NET_ADMIN`
  and `/dev/net/tun` access required by OpenVPN

Podman uses QEMU for the Linux VM. The VM is named `transmission-vm` and is registered as
the default Podman connection so `podman run` targets it without extra flags.

### 3.2 haugene/transmission-openvpn

[haugene/transmission-openvpn](https://github.com/haugene/docker-transmission-openvpn) is a
single container bundling:

- OpenVPN client with PIA support (Panama endpoint)
- iptables kill switch (all non-VPN traffic dropped at container network level)
- PIA port forwarding via the bundled `transmission-openvpn-pia-portforward.sh` script
- Transmission BitTorrent client + web UI

Authentication: `OPENVPN_USERNAME` + `OPENVPN_PASSWORD` (standard PIA account credentials).
Credentials are injected via a `.env` file (permissions 600) written by the setup script from
the macOS login keychain — never stored in the compose file or the git repo.

`LOCAL_NETWORK` allows LAN hosts to reach the Transmission web UI on port 9091 while all
other outbound traffic goes through the VPN.

### 3.3 Trigger-file handoff (container → macOS)

The existing `transmission-done.sh` post-processing script is macOS-specific and cannot run
inside the container. The handoff mechanism:

1. Container: `transmission-post-done.sh` (in `/scripts`, bind-mounted from the host) runs
   inside the container when a torrent completes. It writes a KEY=VALUE trigger file to
   `/data/.done/${TR_TORRENT_HASH}` (the NAS share, visible from both sides).
2. macOS: `transmission-trigger-watcher.sh` LaunchAgent polls `~/.local/mnt/DSMedia/.done/`
   every 60 seconds, maps the container `/data` prefix to the macOS NAS path, and invokes
   the existing `transmission-done.sh` with the correct environment variables.

This preserves the existing FileBot post-processing pipeline without modification.

### 3.4 Port forwarding

PIA port forwarding is handled automatically by the bundled haugene script. No external
port-update companion service is required.

---

## 4. What Gets Removed

This is the significant payoff. If the container approach works, the following can be
decommissioned entirely:

| Component | Purpose | Replaced by |
|-----------|---------|-------------|
| PIA Desktop.app | VPN client GUI | gluetun |
| Split tunnel (NETransparentProxy) | Route Transmission through VPN, Plex around it | Container network namespace (Transmission in VPN; Plex never was) |
| `com.tilsit.pia-proxy-consent` | Auto-click consent dialog | No consent dialog without split tunnel |
| `com.tilsit.pia-split-tunnel-monitor` | Watch for split tunnel activation | Not needed |
| `com.tilsit.pia-monitor` | Monitor PIA connection state | Not needed |
| `com.tilsit.vpn-monitor` | Kill/restart Transmission on VPN changes | Kernel handles it |
| `~/.local/bin/vpn-monitor.sh` | The monitor script | — |
| `~/.local/bin/pia-proxy-consent.sh` | The consent auto-clicker | — |
| `~/.local/bin/pia-split-tunnel-monitor.sh` | The split tunnel watcher | — |
| `plex-vpn-bypass.sh` + LaunchDaemon | PF rules to let Plex bypass VPN | No VPN on host, no bypass needed |

The LaunchDaemon for plex-vpn-bypass runs as root and modifies PF firewall rules. Removing it
simplifies the system significantly and eliminates the only root-level daemon in the setup.

**What stays unchanged:**

- Plex Media Server (native macOS, uses regular internet — this was always the intent)
- rclone (cloud backup, unaffected)
- FileBot + Catch (post-processing pipeline, unaffected)
- NAS NFS mount LaunchAgent (used by Plex, FileBot, and Finder)
- All other setup scripts and infrastructure

---

## 5. Open Questions

> **Status (2026-03-08):** All questions resolved. Notes below document decisions made
> during implementation with haugene/transmission-openvpn on Podman.

### 5.1 NAS bind mount through Podman VM ✅ RESOLVED

**Original question:** Does the container runtime expose the NAS mount through VirtioFS?

**Resolution (updated 2026-03-16):** VirtioFS pass-through of NFS mounts caused file
descriptor caching issues — Apple's Virtualization framework holds FDs indefinitely,
creating `.nfs.*` silly-rename files that block deletion. The solution mounts NFS directly
inside the Podman VM via a systemd `.mount` unit, bypassing VirtioFS for the data path.
The container sees the NAS as a native NFS mount (`type nfs4`), not a VirtioFS mount.

The host-side NFS mount remains for Plex, FileBot, and Finder access. The container
uses `podman run` (not `podman compose`) because `podman-compose` validates host paths
and rejects VM-internal mount points.

On reboot, the VM's systemd mount unit starts the NFS mount before the container. The
`podman-machine-start.sh` wrapper verifies the mount is active before starting the
container.

### 5.2 Container startup ordering ✅ RESOLVED

**Resolution:** The Podman machine start LaunchAgent (`com.<host>.podman-transmission-vm`)
fires at operator login. The wrapper script waits for the Podman socket (up to 30 seconds)
before starting the container. Both LaunchAgents (NAS mount and Podman machine start)
run concurrently at login; there is no guaranteed ordering. The `podman-machine-start.sh`
wrapper explicitly checks that the VM's NFS mount is active before starting the container
with `podman run`, eliminating the startup race condition.

### 5.3 PIA credentials ✅ RESOLVED

**Resolution:** Standard project keychain pattern. `prep-airdrop.sh` retrieves PIA credentials
from 1Password and stores them as a combined `username:password` string in the macOS login
keychain (service: `pia-account-${HOSTNAME_LOWER}`, account: `${HOSTNAME_LOWER}`).
`podman-transmission-setup.sh` retrieves them at deploy time and writes a `.env` file at
`~/containers/transmission/.env` (permissions 600, excluded from git). The compose file
references `${PIA_USERNAME}` and `${PIA_PASSWORD}` from this `.env` via `--env-file`.

### 5.4 Port forwarding handoff mechanism ✅ RESOLVED

**Resolution:** haugene/transmission-openvpn handles PIA port forwarding automatically via its
bundled `transmission-openvpn-pia-portforward.sh` script. No separate port-update service is
needed — this was one of the reasons for choosing haugene over the gluetun +
linuxserver/transmission stack.

### 5.5 Transmission configuration migration ✅ HANDLED

**Resolution:** The haugene image stores Transmission config in the bind-mounted
`~/containers/transmission/config/` directory. Active torrents from the native Transmission.app
cannot be migrated directly (different config format). Migration approach for Phase 2:
re-add active torrents via the web UI. Completed torrents do not need migration — they are
already on the NAS in their final locations.

### 5.6 Remote access to Transmission web UI ✅ RESOLVED

**Resolution:** The `LOCAL_NETWORK` environment variable (set to the LAN subnet, e.g.,
`192.168.1.0/24`) tells haugene to allow traffic from the LAN to reach port 9091. Port 9091 is
exposed in the compose file. The web UI is accessible at `http://tilsit.local:9091` from any
LAN host without macOS firewall changes. Caddy reverse proxy configuration (for external/named
access) is a Phase 2 task in the separate Caddy config repo.

---

## 6. Compose file

The deployed template is at `app-setup/containers/transmission/compose.yml`. Placeholder
variables (`__SERVER_NAME__`, `__PIA_VPN_REGION__`, `__LAN_SUBNET__`, `__OPERATOR_HOME__`,
`__PUID__`, `__PGID__`, `__TZ__`) are replaced by `podman-transmission-setup.sh` at deploy time.

Key design points:

- `OPENVPN_PROVIDER=PIA` + `OPENVPN_CONFIG=<region>` — haugene's built-in PIA OpenVPN support.
  Region must match a file stem in `/etc/openvpn/pia/` inside the container.
- `LOCAL_NETWORK` — allows LAN hosts to reach port 9091 while all other outbound traffic
  routes through the VPN.
- `TRANSMISSION_SCRIPT_TORRENT_DONE_FILENAME=/scripts/transmission-post-done.sh` — the
  container-side trigger that writes to the NAS `.done/` directory for the macOS watcher.
- `restart: unless-stopped` — keeps the container alive within a running Podman machine
  session. Machine restart across reboots is handled by the `podman-machine-start.sh`
  LaunchAgent (separate from this policy).
- Credentials come from `${PIA_USERNAME}` / `${PIA_PASSWORD}` in the `.env` file (600
  permissions, not committed to git).

---

## 7. Migration Plan

> **Implementation status (2026-03-08):** `podman-transmission-setup.sh` and all supporting
> scripts are written and committed. Phases 1–3 are operational steps on tilsit.

### Phase 1: Parallel run on tilsit (non-destructive) — READY TO EXECUTE

1. Run `podman-transmission-setup.sh` on tilsit (deploys Podman + haugene on port 9092).
2. Existing vpn-monitor + PIA GUI continues operating on port 9091.
3. Verify on tilsit (Phase 1 checklist):
   - Confirm PIA VPN region name: `podman run --rm --entrypoint ls haugene/transmission-openvpn /etc/openvpn/pia/ | grep -i panama`
   - Confirm arm64 support: `docker manifest inspect haugene/transmission-openvpn:latest | grep -A2 '"platform"' | grep arm64`
   - Container connects to PIA VPN (check logs: `podman logs transmission-vpn`)
   - Transmission downloads a test torrent to NAS
   - Port forwarding active (check Transmission's reported listening port)
   - Web UI reachable at `http://tilsit.local:9092`
   - Kill switch holds: disconnect VPN (`podman exec transmission-vpn pkill openvpn`),
     confirm Transmission traffic stops
4. Run in parallel for several days to build confidence before cutover.

### Phase 2: Cutover — REQUIRES THESE PREREQUISITES

Prerequisites (must all be complete before cutover):

- [ ] Phase 1 parallel run stable for ≥3 days
- [ ] Caddy reverse proxy config updated (separate repo) to point to port 9091
- [ ] macOS magnet/torrent handler reset from Transmission.app to container web UI

Cutover steps:

1. Stop existing Transmission.app (`launchctl unload ~/Library/LaunchAgents/com.tilsit.transmission.plist` or equivalent).
2. Re-add any active torrents via the container web UI (no config migration — see §5.5).
3. Update `rclone-setup.sh` watch directory if needed (should already point to NAS).
4. Edit `~/containers/transmission/compose.yml`: change `"9092:9091"` → `"9091:9091"`, then:
   `podman compose --project-directory ~/containers/transmission --env-file ~/containers/transmission/.env down && podman compose --project-directory ~/containers/transmission --env-file ~/containers/transmission/.env up -d`
5. Reset macOS magnet/torrent handlers: `duti -s tilsit.local.transmission-web magnet` (exact
   `duti` invocation TBD — depends on Caddy hostname and whether a custom URI handler is installed).
6. Confirm Caddy routes `http://tilsit.local/transmission` → port 9091.

### Phase 3: Remove legacy stack

Only after Phase 2 is confirmed stable (suggest: 1–2 weeks):

1. Unload and remove LaunchAgents: `vpn-monitor`, `pia-proxy-consent`, `pia-split-tunnel-monitor`,
   `pia-monitor`.
2. Unload and remove LaunchDaemon: `plex-vpn-bypass` (root-level PF rules).
3. Remove PIA Desktop.app.
4. Remove associated scripts from `~/.local/bin/`.
5. Update `transmission-setup.sh` to remove or skip the legacy LaunchAgent/plist generation.
6. Update plan.md and this document.

### Rollback

Until Phase 3, rollback is: `podman compose down`, re-enable legacy LaunchAgents. The
existing setup is fully preserved during Phase 1 and Phase 2.

---

## 8. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| NAS NFS mount not ready when Podman machine starts | Medium | High | `podman-machine-start.sh` verifies VM NFS mount before starting container; NFS watchdog timer inside VM auto-remounts stale mounts every 2 minutes |
| NFS mount goes stale while running | Medium | High | NFS watchdog (systemd timer) detects stale mount and remounts automatically; container health check restarts Transmission if it becomes unresponsive |
| Podman machine updates break container networking | Low | Medium | Pin image versions; Podman is a Homebrew formula with pinnable versions |
| PIA changes OpenVPN server config or API | Low | High | haugene is actively maintained for PIA; same risk exists with PIA Desktop |
| haugene port forwarding script fails on PIA API change | Low | Medium | Transmission continues downloading; peering degrades until fixed |
| Podman VM startup is slower than expected | Low | Low | Containers restart gracefully; not latency-sensitive |
| Transmission config migration loses active torrents | Medium | Medium | Re-add active torrents via web UI; completed torrents unaffected |

---

## 9. What This Does Not Address

- **Plex remote access / DDNS:** Unchanged. Plex continues using the host network directly.
- **rclone cloud backup:** Unchanged.
- **FileBot / Catch post-processing:** These run on the macOS host and read from the NAS mount
  as before. The NAS path structure is preserved, so no changes needed.
- **Future containerization of other services:** This proposal is scoped to Transmission only.
  Plex and other services are not candidates for containerization in this proposal.

---

## 10. Success Criteria

The migration is complete when:

- [ ] Transmission downloads exclusively through the VPN (verified by IP check from within
  container: `podman exec transmission-vpn curl -s ifconfig.io` — must return Panama PIA exit IP)
- [ ] Forced VPN disconnect causes Transmission traffic to stop immediately (kill switch test:
  `podman exec transmission-vpn pkill openvpn`, then verify traffic stops)
- [ ] PIA port forwarding is active and Transmission's listening port matches the forwarded port
- [ ] Downloads land in the correct NAS path for FileBot/Catch to process
  (`~/.local/mnt/DSMedia/Media/Torrents/pending-move/`)
- [ ] Web UI is accessible from LAN at `http://tilsit.local:9091`
- [ ] Podman machine and container start automatically after server reboot without intervention
- [ ] Trigger-watcher fires and FileBot processes a completed torrent end-to-end
- [ ] No PIA Desktop app, no vpn-monitor, no pia-proxy-consent, no split tunnel daemons running
  (Phase 3 complete)

---

Draft by Claude Sonnet 4.6 — 2026-02-27; updated 2026-03-08
