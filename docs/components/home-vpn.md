# Home VPN (OpenVPN on YOUR_NAS, Tunnelblick on the Macs)

Remote access to the home LAN from cafés, hotels and airports. Most of it is
not deployed by this repo: the server is a Synology package on YOUR_NAS and the
client is a Tunnelblick config on each Mac. This page records where each part
lives, so it can be found again. The one part this repo deploys is the DDNS
updater on YOUR_SERVER that keeps the VPN hostname current.

Background and design reasons: the blog post "SSH Anywhere: Building a Secure
Tunnel Into My Home Lab" (`projectinsomnia`,
`src/content/blog/2026-04-10-ssh-anywhere-home-lab-vpn.md`). Its port numbers
are out of date; the values below were read from the live configs on
2026-11-04.

## How a connection flows

```text
Tunnelblick on a Mac
  → vpn.example.com:34443      (DNS-only A record → home IP; TCP)
  → router port forward       → YOUR_NAS (192.168.21.20)
  → Synology VPN Server       (OpenVPN, tls-auth + DSM username/password)
  → client gets 10.8.0.x and a route to the LAN (192.168.20.0/22)
  → .local names resolve through YOUR_NAS's DNS Server (192.168.21.20)
```

## Parts and where they live

| Part | Where | Notes |
| --- | --- | --- |
| OpenVPN server | YOUR_NAS, DSM **VPN Server** package. Generated config: `/usr/syno/etc/packages/VPNCenter/openvpn/openvpn.conf` | TCP port 34443, subnet `10.8.0.0/24`, pushes `route 192.168.20.0 255.255.252.0`, `auth SHA512`, tls-auth. Change settings in the DSM UI, not the file. |
| DNS for `.local` | YOUR_NAS, DSM **DNS Server** package, zone `local` | Answers `.local` names for VPN clients, which cannot use mDNS over the tunnel. |
| Public hostname | Cloudflare zone `example.com`, record `vpn.example.com` | **A record, DNS only (grey cloud).** Proxied breaks it: Cloudflare does not carry port 34443. |
| Hostname updater | YOUR_SERVER, `com.<hostname>.cloudflare-ddns` | Deployed by this repo. See `cloudflare-ddns.md`. |
| Client config | Each Mac: `~/Library/Application Support/Tunnelblick/Configurations/VPNConfig.tblk` | `remote vpn.example.com 34443`, `proto tcp-client`, split tunnel (no `redirect-gateway`). Edit it through Tunnelblick (VPN Details → gear → Edit OpenVPN Configuration File); Tunnelblick keeps a protected copy. |
| `.local` resolver | Same `.tblk`: `connected.sh`, `disconnected.sh` | On connect, writes `/etc/resolver/local` with `nameserver 192.168.21.20`. On disconnect, deletes it. |

## Testing from outside

1. Put the Mac on a phone hotspot and turn off Ethernet and home Wi-Fi.
2. Connect `VPNConfig` in Tunnelblick.
3. Check that `cat /etc/resolver/local` shows `nameserver 192.168.21.20`.
4. Run `ssh admin@your-nas.local hostname`. It prints the NAS host name.

If it fails, read the newest log in `/Library/Application Support/Tunnelblick/Logs/`.
A connection that stops at `TCP_CONNECT` to a `2606:4700:` or `104.21.`
address means the hostname resolves to Cloudflare, not home: check that the
record is still DNS only and still points at the home IP.

## History

- 2026-04: built; the client connected to `example.com`.
- 2026-11-03: the Cloudflare Tunnel cutover made `example.com` a proxied
  CNAME, and the VPN stopped connecting from outside.
- 2026-11-04: added `vpn.example.com` (DNS only), pointed the DDNS updater
  and Tunnelblick at it, and confirmed a connection from a phone hotspot.
