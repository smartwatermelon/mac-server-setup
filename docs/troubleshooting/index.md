# Troubleshooting

These pages help you find and fix a problem on the server. Start from the symptom: find the heading that matches what you see, then follow its **Cause**, **Check** and **Fix** parts in order.

Each **Check** uses read-only commands. They show state and change nothing. Each **Fix** tells you what to change. Read the cause before you apply a fix.

## Pages

| Page | Covers |
| --- | --- |
| [Setup](setup.md) | `prep-airdrop.sh` on the dev Mac, `first-boot.sh`, and `run-app-setup.sh` on the server |
| [Plex](plex.md) | Plex Media Server, the NAS mount that Plex reads, the Plex watchdog, and the TVmaze sync |
| [Transmission and VPN](transmission-vpn.md) | The Podman VM, the `transmission-vpn` container, PIA, port forwarding, and VirtioFS access to the NAS |
| [Media pipeline](media-pipeline.md) | The trigger watcher, FileBot, triage, `pending-move/` cleanup, and Catch |
| [Remote access](remote-access.md) | Caddy, TLS certificates, Cloudflare Tunnel and Access, DDNS, and the home VPN |
| [Monitoring](monitoring.md) | The watchdogs, alert email, and msmtp |

## Before you start

- Find which machine you are on. Run `hostname -s` and `whoami`. Most checks run on the server as `admin`.
- Many services run as `operator`. From an `admin` shell, read their LaunchAgents with `sudo launchctl print gui/$(id -u operator)/<label>`, and run their tools with `sudo -iu operator <command>`.
- `<hostname>` in a label or a path is the lowercase server name. `<share>` is `NAS_SHARE_NAME` from `config.conf`.
- Restart a launchd job with `launchctl kickstart -kp`. Reload a changed plist with `launchctl bootout`, then `launchctl bootstrap`.
- Do not unmount the NAS share on the host. Plex reads from it, and the Transmission container sees it through VirtioFS.

## Reference

- [LaunchAgents and LaunchDaemons](../reference/launchagents.md): every label, schedule and log path.
- [Log files](../reference/logs.md): every log that the scripts and jobs write.
- [Ports](../reference/ports.md): every port that the stack listens on or connects to.
