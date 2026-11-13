# Ports

This page lists every TCP port that the stack listens on or connects to, derived from `config/config.conf.template`, the Caddyfile, the plist templates, the `podman run` lines in `app-setup/podman-transmission-setup.sh`, and the scripts that open connections.

"Loopback" means the listener binds to `127.0.0.1`, so only processes on the server can reach it. "All interfaces" means the LAN can reach it, and the internet can too if your router forwards the port.

## Ports the server listens on

| Port | Service | Bind address | Config key | Source |
| --- | --- | --- | --- | --- |
| 443 | Caddy HTTPS: the LAN site (`<hostname>.local`, `localhost`, the server LAN IP), the external hostname, and a catch-all that returns 403 for any other host name | All interfaces | None (fixed) | [`Caddyfile`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/Caddyfile) |
| 80 | Caddy HTTP: redirects to HTTPS | All interfaces | None (fixed) | [`Caddyfile`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/Caddyfile) |
| 8080 | Caddy HTTP site that is the Cloudflare Tunnel origin. Every route checks the Access email header. | Loopback | None (fixed) | [`Caddyfile`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/Caddyfile) |
| 9880 | `media-server.py`, the file server behind Caddy's `/media/` route | Loopback | None (fixed in `media-server.py` and the Caddyfile) | [`media-server.py`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/media-server.py) |
| 9091 | Transmission web UI and RPC, published from the container by `podman run -p 127.0.0.1:<port>:9091` | Loopback | `TRANSMISSION_HOST_PORT` (default `9091`). The Caddyfile proxies `/transmission/` to `127.0.0.1:9091` as a fixed value, so a different host port also needs a Caddyfile change. | [`podman-transmission-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/podman-transmission-setup.sh) |
| 20241 | `cloudflared` `/ready` and `/metrics` (`--metrics`). The tunnel watchdog polls `/ready`. | Loopback | `TUNNEL_METRICS_PORT` (default `20241`) | [`cloudflared-wrapper.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/cloudflared-wrapper.sh) |
| 32599 | TVmaze scrobble webhook listener. Plex posts webhooks to it. | Loopback | `TVMAZE_SCROBBLE_PORT` (default `32599`) | [`tvmaze-scrobble-listener.py`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/tvmaze-scrobble-listener.py) |
| 32400 | Plex Media Server | Set by Plex, not by the repo | None. `plex-setup.sh --custom-port`, or a migration from an earlier server, writes a different port to the Plex preferences (the source port plus 1). | [`plex-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/plex-setup.sh) |
| 22 | SSH (macOS Remote Login), turned on with `systemsetup -setremotelogin on` | All interfaces (macOS default) | None | [`setup-ssh-access.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-ssh-access.sh) |
| 5900 | macOS Screen Sharing. The setup script turns it off, then tells you to turn it on by hand in System Settings. | All interfaces (macOS default) | None | [`setup-remote-desktop.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-remote-desktop.sh) |

## Ports the server connects to

| Port | Destination | Used by | Config key | Source |
| --- | --- | --- | --- | --- |
| 587 | The SMTP relay in the msmtp config (STARTTLS) | `msmtp`, for every alert email | None (fixed in `msmtp-setup.sh`) | [`msmtp-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/msmtp-setup.sh) |
| 443 | Cloudflare API, Let's Encrypt ACME, PIA token API, TVmaze API, public-IP lookups | Caddy (DNS-01), `cloudflare-ddns`, the watchdogs, `transmission-post-start.sh`, `tvmaze-scrobble` | None | Scripts in [`app-setup/templates/`](https://github.com/smartwatermelon/mac-server-setup/tree/main/app-setup/templates) |
| 32400 | Plex Media Server on the server itself (`127.0.0.1` or `localhost`) | `plex-watchdog`, `tvmaze-scrobble`, `transmission-done.sh` (library scans) | `plex.server` in `config.yml` (default `http://localhost:32400`), for `transmission-done.sh` only | [`plex-watchdog.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/plex-watchdog.sh) |
| 2049 | NAS NFS export (NFS default port; the repo does not set it) | `mount-nas-media.sh` (`mount_nfs`) | `NAS_HOSTNAME` and the related NAS keys choose the server, not the port | [`mount-nas-media.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/mount-nas-media.sh) |
| 445 | Time Machine SMB share (SMB default port; the repo does not set it) | macOS Time Machine, configured by `setup-timemachine.sh` | None | [`setup-timemachine.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-timemachine.sh) |

## Ports inside the VPN container

These ports are used inside the Transmission container, through the PIA VPN tunnel. They are not open on the server's own interfaces.

| Port | Use | Config key | Source |
| --- | --- | --- | --- |
| 19999 | PIA port-forwarding API on the VPN gateway | None (fixed) | [`transmission-post-start.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/transmission-post-start.sh), [`pia-pf-probe.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/pia-pf-probe.sh) |
| Assigned by PIA | Transmission peer port. PIA assigns it, and `transmission-post-start.sh` validates it and applies it to Transmission. | None (`TRANSMISSION_PEER_PORT_RANDOM_ON_START=false`) | [`transmission-post-start.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/transmission-post-start.sh) |

## Related pages

- [Caddy](../apps/caddy-README.md): the sites on 443, 80 and 8080.
- [Cloudflare Tunnel](../apps/cloudflare-tunnel-README.md): why the tunnel origin is on loopback.
- [PIA VPN](../apps/pia-vpn-README.md): port forwarding.
- [Config keys](config-keys.md): every key in `config.conf.template`.
