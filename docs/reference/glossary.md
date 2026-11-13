# Glossary

This page defines the terms that you meet in these docs, as the repo's code and docs use them.

Access
:   Cloudflare Access, the Cloudflare Zero Trust service that asks a visitor to sign in before a request reaches the tunnel. An Access policy lists the email addresses that can pass. See [Cloudflare Tunnel](../components/cloudflare-tunnel.md).

Access policy drift
:   A change to the Access policy or tunnel config that does not match the rule the repo expects. The access policy watchdog checks for it every 15 minutes and sends an email when it finds one.

admin account
:   The macOS administrator account that you create in Setup Assistant. You run `first-boot.sh` and the app-setup scripts as this account.

alert-lib
:   `alert-lib.sh`, the shared shell library that the watchdogs source to send alert email and to keep their state in JSON files.

AUD tag
:   The Application Audience tag of a Cloudflare Access application. Cloudflare puts it in the signed token that it sends with each request, and `cloudflared` checks the token against it.

Catch
:   A macOS RSS reader that watches feeds and downloads new `.torrent` files to a folder. In this stack it can feed Transmission. `catch-setup.sh` installs it.

cloudflared
:   The Cloudflare Tunnel daemon. It makes outbound connections to Cloudflare and sends tunnel requests to Caddy on `127.0.0.1:8080`.

Cloudflare Tunnel
:   An outbound-only connection from the server to Cloudflare. With it, the external hostname works with no open inbound ports on the router.

DDNS
:   Dynamic DNS. `cloudflare-ddns` checks the public IP address every 5 minutes and updates a Cloudflare DNS record when the address changes.

dev Mac
:   The Mac that you use to prepare the setup package. It is not the server.

DNS-01
:   An ACME challenge type. Caddy proves that it controls the domain by creating a DNS TXT record through the Cloudflare API, so Let's Encrypt can issue a certificate without an inbound connection. See [Caddy](../components/caddy.md).

FileBot
:   A media renaming tool. `transmission-done.sh` runs it on each completed download to match the file to a TV episode or movie and to move it into the media library. See [Transmission and FileBot](../components/transmission-filebot.md).

golden config
:   The file of Plex settings that the Plex watchdog treats as correct. `plex-watchdog-ctl accept` updates it, and `plex-watchdog-ctl revert` pushes it back to Plex. See [Plex watchdog](../components/plex-watchdog.md).

hardware fingerprint
:   The hardware UUID of the target Mac, recorded by `prep-airdrop.sh`. `first-boot.sh` stops if the Mac it runs on does not match, so the package cannot run on the wrong machine.

LaunchAgent
:   A launchd job for one user account. It starts only when that account has a GUI login. See [LaunchAgents and LaunchDaemons](launchagents.md).

LaunchDaemon
:   A launchd job that starts at boot without a login. It runs as root unless its plist sets `UserName`.

msmtp
:   A small SMTP client. All the watchdogs send their alert email through it, with the config that `msmtp-setup.sh` writes for operator. See [Monitoring](../components/monitoring.md).

operator account
:   The standard (non-admin) macOS account that runs the media services. It logs in automatically at boot, so its LaunchAgents start without anyone at the keyboard. See [Operator](../operator.md).

pending-move
:   The folder where Transmission puts completed downloads. FileBot processes them from there, and `pending-move-cleanup.sh` removes processed folders later.

PIA
:   Private Internet Access, the VPN provider that the Transmission container connects through. See [PIA VPN](../components/pia-vpn.md).

placeholder token
:   A `__NAME__` string in a template file, such as `__HOSTNAME_LOWER__`. The setup script that deploys the template replaces each token with a value from `config.conf`.

Podman machine
:   The Linux VM that Podman runs containers in on macOS. This stack uses one rootful machine named `transmission-vm`.

port forwarding
:   A PIA feature that opens one inbound port on the VPN server and forwards it to the container. Transmission uses it as its peer port so that other peers can connect in. Not every PIA region supports it.

setup package
:   The folder that `prep-airdrop.sh` builds on the dev Mac (by default `~/<hostname>-setup`). It holds the scripts, config and credentials, and you copy it to the server, for example with AirDrop.

stable signing
:   The repo's fix for TCC grants that a `brew upgrade` would remove. `stable-sign.sh` keeps copies of some Homebrew binaries at fixed paths under `/usr/local/stable`, signed with a local identity that does not change. See [Stable signing](../components/stable-signing.md).

supervisor
:   `podman-machine-start.sh`, the script that the `podman-transmission-vm` LaunchAgent runs. It starts the Podman machine and the Transmission container, then checks them in a loop and does not exit.

TCC
:   Transparency, Consent and Control, the macOS privacy system. It asks the user before an app can use protected resources such as network volumes or Full Disk Access, and it records each answer for that app's path and code signature.

tunnel origin
:   The local service that the tunnel sends requests to. In this stack it is a Caddy site on `127.0.0.1:8080`.

trigger file
:   A small file that `transmission-post-done.sh` writes inside the container when a torrent finishes. The host trigger watcher reads it and starts `transmission-done.sh`.

VirtioFS
:   The file-sharing method that the Podman machine uses to give the VM access to host folders. The Transmission container reaches the NAS media mount through it.
