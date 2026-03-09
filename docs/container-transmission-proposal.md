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
  • NAS SMB mount — still needed for Plex and trigger-watcher
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

### 3.1 OrbStack

[OrbStack](https://orbstack.dev) is the container runtime. Preferred over Docker Desktop because:

- Lower memory overhead (~300MB vs ~1GB+ for Docker Desktop)
- Faster startup (Linux VM in ~1 second vs ~10-15s)
- Native Apple Silicon support
- Better macOS filesystem integration (VirtioFS)
- `orb` CLI is simpler than Docker Desktop's tooling

OrbStack's containers run in a Linux VM via Apple Virtualization.framework. This gives containers
genuine Linux kernel networking (iptables, WireGuard, network namespaces) — not emulated.

### 3.2 gluetun

[gluetun](https://github.com/qdm12/gluetun) (`qmcgaw/gluetun`) is a VPN client container with:

- Native PIA support (WireGuard and OpenVPN)
- Built-in iptables kill switch
- PIA dynamic port forwarding via API (`VPN_PORT_FORWARDING=on`)
- HTTP control server for reading the forwarded port
- Automatic server selection and reconnection

gluetun authenticates to PIA via their token API (username + password → token → WireGuard
config). No PIA Desktop app is involved.

### 3.3 Transmission

[linuxserver/transmission](https://hub.docker.com/r/linuxserver/transmission) runs with
`network_mode: "service:gluetun"`, meaning it shares gluetun's network namespace entirely. From
the Linux kernel's perspective, gluetun and Transmission are the same network entity.

The web UI replaces the macOS Transmission.app. It is accessible at
`http://tilsit.local:9091` from any browser on the LAN.

### 3.4 Port forwarding update

PIA's forwarded port is dynamic and changes on reconnection. gluetun exposes it at
`http://localhost:8000/v1/openvpn/portforwarded`. A small companion script (run on a timer or
triggered by gluetun's port change event) reads this endpoint and updates Transmission's
listening port via its RPC API. This is a solved pattern with documented recipes.

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
- NAS SMB mount LaunchAgent (still needed for Plex's media access)
- All other setup scripts and infrastructure

---

## 5. Open Questions

> **Status (2026-03-08):** All questions resolved. Notes below document decisions made
> during implementation with haugene/transmission-openvpn on Podman.

### 5.1 NAS bind mount through Podman VM ✅ RESOLVED

**Original question (OrbStack VirtioFS):** Does the container runtime expose the NAS SMB
mount or the empty underlying directory?

**Resolution:** Podman uses QEMU (not Apple Virtualization.framework), so VirtioFS specifics
don't apply. The macOS-mounted SMB path (`~/.local/mnt/DSMedia`) is bind-mounted directly into
the Podman VM. `podman-transmission-setup.sh` validates this at deploy time:

```bash
sudo -iu "${OPERATOR_USERNAME}" podman run --rm \
  -v "${NAS_MOUNT}:/test:ro" alpine ls /test
```

If the validation fails (NAS not mounted, empty listing), the setup script emits a warning and
documents the fallback in `docs/container-transmission-proposal.md §5.1`. On reboot, the NAS
LaunchAgent and the Podman machine start LaunchAgent both fire at login — the machine start
wrapper does not explicitly wait for the NAS mount, so if the SMB mount is slow, the first
`compose up` may see an empty `/data`. Recovery: `podman compose up -d` re-runs automatically
on next login, or manually after confirming the NAS is mounted.

### 5.2 Container startup ordering ✅ RESOLVED

**Resolution:** The Podman machine start LaunchAgent (`com.<host>.podman-transmission-vm`)
fires at operator login. The wrapper script waits for the Podman socket (up to 30 seconds)
before running `podman compose up -d`. Both LaunchAgents (NAS mount and Podman machine start)
run concurrently at login; there is no guaranteed ordering. If the NAS mount isn't ready when
compose starts, Transmission may start with an empty `/data` bind — this is the same risk as
§5.1 and has the same recovery path. `restart: unless-stopped` keeps the container running once
it starts successfully.

### 5.3 PIA credentials ✅ RESOLVED

**Resolution:** Standard project keychain pattern. `prep-airdrop.sh` retrieves PIA credentials
from 1Password and stores them as a combined `username:password` string in the macOS login
keychain (service: `pia-account-${HOSTNAME_LOWER}`, account: `${HOSTNAME_LOWER}`).
`podman-transmission-setup.sh` retrieves them at deploy time and writes a `.env` file at
`~/containers/transmission/.env` (permissions 600, excluded from git). The compose file
references `${PIA_USERNAME}` and `${PIA_PASSWORD}` from this `.env`.

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

## 6. Draft compose.yml

This is illustrative — not final. Sensitive values are placeholders.

```yaml
# /Users/operator/containers/transmission/compose.yml

services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=private internet access
      - VPN_TYPE=wireguard
      - OPENVPN_USER=${PIA_USERNAME}
      - OPENVPN_PASSWORD=${PIA_PASSWORD}
      - SERVER_REGIONS=US East          # or nearest/preferred region
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=private internet access
      - FIREWALL_OUTBOUND_SUBNETS=192.168.1.0/24  # LAN: for Transmission RPC access
    ports:
      - 9091:9091                       # Transmission web UI
      - 51413:51413                     # Transmission peer port (dynamic — see §5.4)
      - 51413:51413/udp
    volumes:
      - gluetun-data:/gluetun
    restart: unless-stopped

  transmission:
    image: lscr.io/linuxserver/transmission:latest
    container_name: transmission
    network_mode: "service:gluetun"     # shares gluetun's network namespace
    environment:
      - PUID=502                        # operator UID on tilsit
      - PGID=20                         # staff GID
      - TZ=America/Los_Angeles
    volumes:
      - transmission-config:/config
      - /Users/operator/.local/mnt/DSMedia:/data   # see §5.1
    restart: unless-stopped
    depends_on:
      - gluetun

volumes:
  gluetun-data:
  transmission-config:
```

Key points:

- `FIREWALL_OUTBOUND_SUBNETS` allows the Transmission web UI to be reachable from the LAN while
  all other outbound traffic goes through the VPN.
- `network_mode: "service:gluetun"` means Transmission has no independent network interface —
  it is fully contained within gluetun's namespace.
- Download/incomplete paths within the container map to `/data/Media/Torrents/...` — matching
  the existing NAS structure.

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
4. Run `podman-transmission-setup.sh --force` with `TRANSMISSION_PORT=9091` to switch to primary port.
   (Or manually edit compose.yml port mapping and restart: `podman compose down && podman compose up -d`)
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
| NAS bind mount doesn't work through VirtioFS | Medium | High | VM-level SMB mount fallback (§5.1) |
| OrbStack updates break container networking | Low | Medium | Pin image versions; monitor OrbStack changelog |
| PIA changes WireGuard API | Low | High | gluetun is actively maintained for PIA; same risk exists with PIA Desktop |
| Port forwarding update lag causes poor peering | Low | Medium | Port-update service polls gluetun endpoint every 30s |
| OrbStack VM startup is slower than expected | Low | Low | Containers restart gracefully; not latency-sensitive |
| Transmission config migration loses active torrents | Medium | Medium | Export torrent files before migration; re-add if necessary |

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
  container: `docker exec transmission curl -s ifconfig.io`)
- [ ] Forced VPN disconnect causes Transmission traffic to stop immediately (kill switch test)
- [ ] PIA port forwarding is active and Transmission's listening port matches
- [ ] Downloads land in the correct NAS path for FileBot/Catch to process
- [ ] Web UI is accessible from LAN at `http://tilsit.local:9091`
- [ ] OrbStack and containers start automatically after server reboot without intervention
- [ ] No PIA Desktop app, no vpn-monitor, no pia-proxy-consent, no split tunnel daemons running

---

Draft by Claude Sonnet 4.6 — 2026-02-27; updated 2026-03-08
