# Proposal: Containerized Transmission with gluetun VPN

**Status:** Draft — for review, not yet approved for implementation
**Date:** 2026-02-27
**Motivation:** Replace the current PIA Desktop + split tunnel + shell script monitoring stack with a
container-based architecture that provides kernel-level VPN enforcement and eliminates recurring
reliability problems.

---

## 1. Problem Statement

The current Transmission + VPN setup has required multiple debugging sessions and patches:

| Problem | Root Cause | Fix Applied |
|---------|-----------|-------------|
| Transmission on wrong IP after VPN restart | `launch_transmission` failure → `set -e` crash-loop | `|| log "WARNING"` guards (PR #75) |
| PIA consent dialog ignored for 90+ minutes | `StartInterval` job exits in ~3s → launchd throttle escalation | Converted to daemon (PR #75) |
| Split tunnel loses consent after reboot | NETransparentProxy loses signature at boot | pia-proxy-consent auto-clicker daemon |
| Transmission briefly unguarded on monitor restart | KeepAlive restarts vpn-monitor before kill completes | Mitigated by PR #75, not eliminated |

These are symptoms of the same underlying architecture mismatch: enforcing VPN-only networking at
the **application layer** (a shell script that polls every 5 seconds and kills a process) is
inherently racy. The consent dialog problem exists because macOS's split tunnel mechanism
(NETransparentProxy) is designed for interactive use, not unattended servers.

---

## 2. Proposed Architecture

Replace the entire PIA Desktop + split tunnel + monitoring stack with:

```
┌─────────────────────────────────────────────────────────────┐
│  OrbStack (Apple Virtualization.framework — Linux VM)        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  gluetun container                                    │   │
│  │  • WireGuard client (PIA, no GUI)                    │   │
│  │  • iptables kill switch: blocks all non-VPN traffic  │   │
│  │  • PIA port forwarding via API                       │   │
│  │  • Exposes port 9091 (Transmission web UI)           │   │
│  │                                                      │   │
│  │  ┌────────────────────────────────────────────────┐  │   │
│  │  │  Transmission container                         │  │   │
│  │  │  network_mode: service:gluetun                 │  │   │
│  │  │  (shares gluetun's network namespace)          │  │   │
│  │  │  • linuxserver/transmission                    │  │   │
│  │  │  • Web UI only (no macOS .app)                 │  │   │
│  │  │  • Bind mount: NAS at /data                    │  │   │
│  │  └────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

macOS host
  • Plex.app — unaffected, uses regular internet directly
  • rclone, FileBot, Catch — unaffected
  • NAS SMB mount — still needed for Plex
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

These must be answered before implementation begins.

### 5.1 NAS bind mount through OrbStack VirtioFS ⚠️ CRITICAL

**Question:** When `~/.local/mnt/DSMedia` is an active SMB mount on macOS, does OrbStack's
VirtioFS expose the mounted content (the NAS share) or the empty underlying directory to the
Linux VM?

**Why it matters:** If VirtioFS sees the empty directory, a bind mount of that path into the
container gives Transmission an empty `/data` — all downloads would fail silently (or write to
a path that fills the system drive).

**How to test (one command, no side effects):**

```bash
docker run --rm -v /Users/operator/.local/mnt/DSMedia:/test alpine ls /test
```

Expected if working: NAS directory listing. Expected if broken: empty output.

**Fallback if broken:** Mount the SMB share from within the OrbStack Linux VM's `/etc/fstab`
instead of relying on the macOS mount. This is more reliable regardless — it removes the
dependency on the macOS LaunchAgent mount being active before containers start.

### 5.2 Container startup ordering

**Question:** Does OrbStack start containers before or after the operator's login LaunchAgents
fire? Specifically, will the NAS LaunchAgent have mounted `~/.local/mnt/DSMedia` before
Transmission's container starts and looks for `/data`?

If using Option A (macOS bind mount), startup order matters. If using the fallback (VM-level
SMB mount), it does not.

### 5.3 PIA WireGuard credentials

**Question:** What format does gluetun expect for PIA WireGuard credentials, and how are they
stored securely on the server?

gluetun with PIA WireGuard uses:

- `OPENVPN_USER` / `OPENVPN_PASSWORD` (PIA account credentials)
- gluetun generates the WireGuard keypair and exchanges it with PIA's API at startup

Credentials need to be passed to the container without appearing in the compose file. Options:

- Docker secrets
- `.env` file with restricted permissions (600), excluded from git
- Retrieved from macOS keychain at compose-up time and injected as environment variables

The keychain approach (consistent with how the rest of the project handles credentials) is
preferred but requires a wrapper script around `docker compose up`.

### 5.4 Port forwarding handoff mechanism

**Question:** How does Transmission learn its externally-reachable port when PIA assigns a new
one?

gluetun's port-forwarding HTTP endpoint (`localhost:8000/v1/openvpn/portforwarded`) is accessible
from within the gluetun network namespace — i.e., from within the Transmission container. A
small script running inside the Transmission container can poll this endpoint and update
Transmission's port via RPC when it changes.

The `linuxserver/transmission` image supports custom scripts via `/config/custom-cont-init.d/`
and `/config/custom-services.d/`. A port-update service fits naturally here.

### 5.5 Transmission configuration migration

The existing Transmission installation has torrent history, download locations, and preferences
(bandwidth limits, etc.) stored in macOS's `~/Library/Application Support/Transmission/`. The
Linux container uses a different config format but preserves torrent state (`.torrent` files and
resume data). A migration plan is needed for active torrents.

### 5.6 Remote access to Transmission web UI

The web UI at port 9091 needs to be accessible from the LAN. OrbStack exposes container ports
to the macOS host automatically; the macOS host's firewall may need a rule to allow 9091 from
the LAN. This replaces the current setup where the macOS Transmission.app is directly accessible.

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

### Phase 0: Validate unknowns (no server changes)

1. Test NAS bind mount on the dev Mac (OrbStack installed, run the `docker run --rm` test above
   against a locally-mounted share).
2. Confirm gluetun connects to PIA WireGuard successfully in a scratch environment.
3. Confirm port forwarding endpoint is reachable from within the Transmission container.
4. Decide on credential injection strategy (§5.3).

### Phase 1: Parallel run on tilsit (non-destructive)

1. Install OrbStack on tilsit.
2. Deploy compose stack with Transmission on a different port (e.g., 9092) alongside the
   existing setup.
3. Run both stacks simultaneously — existing vpn-monitor + PIA GUI continues operating.
4. Verify: gluetun connects, Transmission downloads to NAS, port forwarding works, web UI
   accessible, kill switch holds on forced VPN disconnect.
5. Run parallel for several days to build confidence.

### Phase 2: Cutover

1. Stop existing Transmission.app.
2. Migrate any active torrents (copy resume data to container config volume).
3. Switch compose stack to port 9091.
4. Confirm operation.

### Phase 3: Remove legacy stack

Only after Phase 2 is confirmed stable (suggest: 1–2 weeks):

1. Unload and remove LaunchAgents: vpn-monitor, pia-proxy-consent, pia-split-tunnel-monitor,
   pia-monitor.
2. Unload and remove LaunchDaemon: plex-vpn-bypass (root-level).
3. Remove PIA Desktop.app.
4. Remove associated scripts from `~/.local/bin/`.
5. Remove transmission-setup.sh's plist generation for the old LaunchAgents (or archive them).
6. Update plan.md and docs.

### Rollback

Until Phase 3, rollback is: stop OrbStack containers, re-enable legacy LaunchAgents. The
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

*Draft by Claude Sonnet 4.6 — 2026-02-27*
