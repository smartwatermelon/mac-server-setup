# PIA macOS Split Tunnel Bug — Transparent Proxy Failure

## Summary

PIA's macOS split tunnel transparent proxy is broken on macOS 26.3 (Apple Silicon). The proxy correctly identifies bypass apps and binds outbound sockets to the physical interface IP, but data forwarding between the app's network flow and the outbound socket fails for **all** bypass apps. Every proxied session closes with zero bytes transferred.

This affects **both** OpenVPN and WireGuard protocols.

## Affected Versions

| Component | Version |
|-----------|---------|
| PIA Desktop | 3.7.0+08412 |
| macOS | 26.3 (Darwin 25.3.0) |
| Architecture | Apple Silicon (aarch64-apple-darwin25.1.0) |
| OpenVPN | Tested and broken |
| WireGuard | Tested and broken |

## Configuration

Split tunnel mode: **Bypass VPN** (exclude) with these apps:

```json
{
  "splitTunnelEnabled": true,
  "splitTunnelRules": [
    {"mode": "exclude", "path": "/Applications/Plex Media Server.app"},
    {"mode": "exclude", "path": "/Applications/Backblaze.app"},
    {"mode": "exclude", "path": "/Applications/No-IP DUC.app"},
    {"mode": "exclude", "path": "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"}
  ],
  "splitTunnelDNS": true,
  "killswitch": "on",
  "allowLAN": true,
  "blockIPv6": true,
  "bypassSubnets": [{"mode": "exclude", "subnet": "10.0.15.0/24"}]
}
```

## How the Transparent Proxy Should Work

1. App (e.g., Plex) initiates a network connection
2. Network Extension intercepts the flow
3. Proxy identifies the app by bundle ID (e.g., `com.plexapp.plexmediaserver`)
4. Proxy creates a new TCP/UDP socket bound to the physical interface IP (`bindIp: 10.0.15.15`)
5. Proxy forwards data between the app's flow and the new outbound socket
6. Traffic exits via physical interface, bypassing VPN

## What Actually Happens

Steps 1-4 succeed. Step 5 fails. The proxy correctly identifies the app and binds to the right IP, but the flow-to-socket data forwarding breaks every time. All sessions close with zero bytes transferred.

### Error Types Observed

From `/Library/Application Support/com.privateinternetaccess.vpn/transparent_proxy.log`:

**1. `ioOnClosedChannel` — socket closed before data could be forwarded**

```text
[2026-02-16 11:49:40:7270] [ChannelCreatorTCP.swift:50] debug: id: 133 com.plexapp.plexmediaserver Creating, binding and connecting a new TCP socket - endpoint: 54.172.39.248:443 with bindIp: 10.0.15.15
[2026-02-16 11:49:50:9400] [InboundHandlerTCP.swift:25] debug: id: 133 Destructor called for InboundHandlerTCP
[2026-02-16 11:50:07:9760] [FlowForwarderTCP.swift:56] error: id: 133 ioOnClosedChannel while sending a TCP datagram through the socket com.plexapp.plexmediaserver
[2026-02-16 11:50:07:9770] [ProxySession.swift:25] info: id: 133 Terminating the session
[2026-02-16 11:50:07:9770] [ProxySessionTCP.swift:31] debug: id: 133 Destructor: ProxySession closed. rxBytes=0 MB txBytes=0 MB com.plexapp.plexmediaserver
```

**2. `Empty buffer` — flow read returns empty data**

```text
[2026-02-16 12:03:36:5310] [FlowForwarderTCP.swift:32] error: id: 147 Empty buffer occurred during TCP flow.readData() com.plexapp.plexmediaserver
[2026-02-16 12:00:46:2000] [FlowForwarderTCP.swift:32] error: id: 140 Empty buffer occurred during TCP flow.readData() com.apple.Safari
[2026-02-16 12:00:39:4100] [FlowForwarderUDP.swift:34] error: id: 136 Empty buffer occurred during UDP flow.readDatagrams() com.apple.Safari.SafeBrowsing
```

**3. `connectTimeout` — outbound socket fails to connect**

```text
[2026-02-16 12:06:18:3400] [ProxySessionTCP.swift:59] error: id: 152 Unable to create channel: connectTimeout(NIOCore.TimeAmount(nanoseconds: 10000000000)), dropping the flow.
[2026-02-16 12:06:18:3410] [ProxySessionTCP.swift:31] debug: id: 152 Destructor: ProxySession closed. rxBytes=Zero KB txBytes=Zero KB com.plexapp.plexmediaserver
```

### Multiple Apps Affected

The failure is not app-specific. Every bypass app exhibits the same behavior:

- `com.plexapp.plexmediaserver` — ioOnClosedChannel, Empty buffer, connectTimeout
- `com.apple.Safari` — Empty buffer, connectTimeout
- `com.apple.Safari.SafeBrowsing` — Empty buffer (UDP)

### Multiple Destinations Affected

```text
54.172.39.248:443   (plex.tv)     — ioOnClosedChannel, 0 bytes
44.210.41.33:443    (plex.tv)     — ioOnClosedChannel, 0 bytes
34.238.225.186:443  (plex.tv)     — ioOnClosedChannel, 0 bytes
172.64.151.205:443  (plex.tv)     — ioOnClosedChannel, 0 bytes
174.31.0.47:32400   (self-check)  — connectTimeout, 0 bytes
```

## Root Cause Hypothesis

The proxy binds outbound sockets to the physical IP (`10.0.15.15` on `en0`) but the OS routing table still routes traffic through the VPN tunnel (`utun4`) because PIA's `0/1` catch-all route takes precedence over the default route. The socket has the correct source IP but packets are still routed through the VPN interface, causing the connection to fail or time out.

This would explain why:

- Binding succeeds (the IP exists on en0)
- Connection fails (packets go through utun4 instead of en0)
- The NIO channel closes or times out (remote host never receives the SYN)

A kernel-level policy routing mechanism (like PF `route-to`) is needed to override the routing table decision based on source IP.

## Workaround: PF route-to Rules

PF (Packet Filter) rules loaded into a custom anchor bypass the issue entirely by operating at the kernel level, below PIA's userspace proxy:

```text
table <rfc1918> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 }
pass in quick on en0 proto tcp to port 32400
pass out quick route-to (en0 10.0.15.1) from 10.0.15.15 to ! <rfc1918>
```

Loaded into anchor `com.apple/100.tilsit.vpn-bypass`:

```bash
echo "${RULES}" | sudo pfctl -a "com.apple/100.tilsit.vpn-bypass" -f -
```

Verification:

```bash
curl --interface 10.0.15.15 http://checkip.amazonaws.com
# Returns: 174.31.0.47 (home IP, NOT VPN IP 91.90.126.18)
```

Combined with Plex `customConnections = https://174.31.0.47:32400`, this restores full Plex remote access.

## Relevant Source Files

From the `pia-foss/mac-split-tunnel` repository:

| File | Line | Role |
|------|------|------|
| `ChannelCreatorTCP.swift` | 50 | Creates and binds outbound socket |
| `InboundHandlerTCP.swift` | 25 | Handles inbound socket data |
| `FlowForwarderTCP.swift` | 32 | Reads from app flow (empty buffer) |
| `FlowForwarderTCP.swift` | 56 | Writes to socket (ioOnClosedChannel) |
| `FlowForwarderUDP.swift` | 34 | Reads UDP datagrams (empty buffer) |
| `ProxySessionTCP.swift` | 31 | Session destructor (logs bytes) |
| `ProxySessionTCP.swift` | 59 | Channel creation (connectTimeout) |
| `ProxySession.swift` | 25 | Session termination |

## Network Context

| Item | Value |
|------|-------|
| Physical interface | en0 |
| Physical IP | 10.0.15.15 |
| VPN tunnel interface | utun4 |
| VPN tunnel IP | 10.16.11.143 |
| VPN exit IP | 91.90.126.18 |
| Default gateway | 10.0.15.1 |
| Home public IP | 174.31.0.47 |
| VPN region | Panama |

---

## Draft GitHub Issue for `pia-foss/desktop`

### Title

macOS split tunnel transparent proxy fails for all bypass apps — zero bytes transferred (3.7.0, macOS 26.3, Apple Silicon)

### Body

**Environment:**

- PIA version: 3.7.0+08412
- macOS 26.3 (Darwin 25.3.0)
- Apple Silicon (Mac Mini)
- Split tunnel mode: Bypass VPN (exclude)
- Tested with both OpenVPN and WireGuard — same failure

**Description:**

The macOS transparent proxy (Network Extension) fails to forward data for all bypass apps. The proxy correctly identifies apps by bundle ID and binds outbound sockets to the physical interface IP, but every session closes with zero bytes transferred.

**Steps to reproduce:**

1. Enable split tunnel in Bypass VPN mode
2. Add any application to the bypass list (e.g., Safari)
3. Connect to VPN
4. Open the bypass application and try to access any website
5. Check `transparent_proxy.log`

**Expected:** Bypass app traffic routes through physical interface, bypassing VPN.

**Actual:** All connections fail. Proxy log shows:

```text
[ChannelCreatorTCP.swift:50] debug: id: 133 com.plexapp.plexmediaserver Creating, binding and connecting a new TCP socket - endpoint: 54.172.39.248:443 with bindIp: 10.0.15.15
[FlowForwarderTCP.swift:56] error: id: 133 ioOnClosedChannel while sending a TCP datagram through the socket com.plexapp.plexmediaserver
[ProxySessionTCP.swift:31] debug: id: 133 Destructor: ProxySession closed. rxBytes=0 MB txBytes=0 MB com.plexapp.plexmediaserver
```

Error types observed across all bypass apps:

- `ioOnClosedChannel while sending a TCP datagram through the socket` (FlowForwarderTCP.swift:56)
- `Empty buffer occurred during TCP flow.readData()` (FlowForwarderTCP.swift:32)
- `Empty buffer occurred during UDP flow.readDatagrams()` (FlowForwarderUDP.swift:34)
- `Unable to create channel: connectTimeout` (ProxySessionTCP.swift:59)

Every session destructor shows `rxBytes=0 txBytes=0`.

**Affected apps:** All bypass apps tested — Plex Media Server, Safari, Safari.SafeBrowsing (UDP). This is not app-specific.

**Root cause hypothesis:** The proxy binds the outbound socket to the physical IP (10.0.15.15 on en0) but the routing table still sends packets through utun because the 0/1 VPN catch-all route has higher priority than the default route. Source IP binding alone does not control the outbound interface on macOS; a policy routing mechanism like PF `route-to` is needed.

**Workaround:** PF `route-to` rules in a custom anchor force traffic from the physical IP through the physical interface at the kernel level:

```text
table <rfc1918> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 }
pass in quick on en0 proto tcp to port 32400
pass out quick route-to (en0 10.0.15.1) from 10.0.15.15 to ! <rfc1918>
```

This works because PF evaluates before the routing table decision, overriding the VPN catch-all route for matched traffic.

**Related repository:** `pia-foss/mac-split-tunnel` (contains the transparent proxy Swift source)
