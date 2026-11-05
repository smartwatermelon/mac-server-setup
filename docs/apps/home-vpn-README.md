# Home VPN (OpenVPN on ROMANO, Tunnelblick on the Macs)

Remote access to the home LAN from cafés, hotels and airports. Most of it is
not deployed by this repo: the server is a Synology package on ROMANO and the
client is a Tunnelblick config on each Mac. This page records where each part
lives, so it can be found again. The one part this repo deploys is the DDNS
updater on TILSIT that keeps the VPN hostname current.

Background and design reasons: the blog post "SSH Anywhere: Building a Secure
Tunnel Into My Home Lab" (`projectinsomnia`,
`src/content/blog/2026-04-10-ssh-anywhere-home-lab-vpn.md`). Its port numbers
are out of date; the values below were read from the live configs on
2026-11-04.

## How a connection flows

```text
Tunnelblick on a Mac
  → vpn.tilsit.vip:34443      (DNS-only A record → home IP; TCP)
  → router port forward       → ROMANO (10.0.15.67)
  → Synology VPN Server       (OpenVPN, tls-auth + DSM username/password)
  → client gets 172.16.0.x and a route to the LAN (10.0.12.0/22)
  → .local names resolve through ROMANO's DNS Server (10.0.15.67)
```

## Parts and where they live

| Part | Where | Notes |
| --- | --- | --- |
| OpenVPN server | ROMANO, DSM **VPN Server** package. Generated config: `/usr/syno/etc/packages/VPNCenter/openvpn/openvpn.conf` | TCP port 34443, subnet `172.16.0.0/24`, pushes `route 10.0.12.0 255.255.252.0`, `auth SHA512`, tls-auth. Change settings in the DSM UI, not the file. |
| DNS for `.local` | ROMANO, DSM **DNS Server** package, zone `local` | Answers `.local` names for VPN clients, which cannot use mDNS over the tunnel. |
| Public hostname | Cloudflare zone `tilsit.vip`, record `vpn.tilsit.vip` | **A record, DNS only (grey cloud).** Proxied breaks it: Cloudflare does not carry port 34443. |
| Hostname updater | TILSIT, `com.tilsit.cloudflare-ddns` | Deployed by this repo. See `cloudflare-ddns-README.md`. |
| Client config | Each Mac: `~/Library/Application Support/Tunnelblick/Configurations/VPNConfig.tblk` | `remote vpn.tilsit.vip 34443`, `proto tcp-client`, split tunnel (no `redirect-gateway`). Edit it through Tunnelblick (VPN Details → gear → Edit OpenVPN Configuration File); Tunnelblick keeps a protected copy. |
| `.local` resolver | Same `.tblk`: `connected.sh`, `disconnected.sh` | On connect, writes `/etc/resolver/local` with `nameserver 10.0.15.67`. On disconnect, deletes it. |

## Testing from outside

1. Put the Mac on a phone hotspot and turn off Ethernet and home Wi-Fi.
2. Connect `VPNConfig` in Tunnelblick.
3. Check that `cat /etc/resolver/local` shows `nameserver 10.0.15.67`.
4. Run `ssh dsadmin@romano.local hostname`. It prints `ROMANO`.

If it fails, read the newest log in `/Library/Application Support/Tunnelblick/Logs/`.
A connection that stops at `TCP_CONNECT` to a `2606:4700:` or `104.21.`
address means the hostname resolves to Cloudflare, not home: check that the
record is still DNS only and still points at the home IP.

## History

- 2026-04: built; the client connected to `tilsit.vip`.
- 2026-11-03: the Cloudflare Tunnel cutover made `tilsit.vip` a proxied
  CNAME, and the VPN stopped connecting from outside.
- 2026-11-04: added `vpn.tilsit.vip` (DNS only), pointed the DDNS updater
  and Tunnelblick at it, and confirmed a connection from a phone hotspot.
