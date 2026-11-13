# Log files

This page lists every log file that the repo's scripts and launchd jobs write, derived from the `LOG_FILE` assignments, `StandardOutPath` and `StandardErrorPath` keys, and other `.log` paths in `app-setup/` and `scripts/`.

`<hostname>` is the lowercase server name. `~operator` is the home folder of the operator account. `~admin` is the home folder of the admin account that runs the setup scripts.

The "Rotation" column says what keeps the file small:

- **logrotate**: a pattern in [`config/logrotate.conf`](https://github.com/smartwatermelon/mac-server-setup/blob/main/config/logrotate.conf) matches the file (size 10M or daily, 30 kept).
- **Self**: the writer caps or empties the file itself.
- **None in repo**: no rotation is configured in the repo.

## Setup logs (admin account)

These logs are written while you run the setup scripts.

| Path | Writer | Contents | Rotation |
| --- | --- | --- | --- |
| `~admin/.local/state/<hostname>-setup.log` | `scripts/server/first-boot.sh` and the `scripts/server/setup-*.sh` modules that it calls | First-boot provisioning: every module's progress, warnings and errors. First-boot renames an earlier copy to `<hostname>-setup-<YYYYMMDD-HHMMSS>.log` before it starts. | logrotate |
| `~admin/.local/state/<hostname>-app-setup.log` | `app-setup/run-app-setup.sh` | The app-setup orchestrator: which setup scripts ran and their results | None in repo |
| `~admin/.local/state/<hostname>-apps.log` | `app-setup/plex-setup.sh`, `rclone-setup.sh`, `podman-transmission-setup.sh`, `filebot-setup.sh`, `catch-setup.sh` | Progress and errors of each application setup script | logrotate |
| `~admin/.local/state/<hostname>-msmtp-setup.log` | `app-setup/msmtp-setup.sh` | msmtp setup and its test email | None in repo |
| `~admin/.local/state/<hostname>-plex-watchdog-setup.log` | `app-setup/plex-watchdog-setup.sh` | Plex watchdog setup | None in repo |
| `/tmp/plex_rsync_<pid>.log` | `app-setup/plex-setup.sh` | `rsync` output while Plex data is copied from an earlier server | The logrotate `postrotate` step deletes copies older than 7 days |
| `~admin/.local/state/<hostname>-mount.log` | `~admin/.local/bin/mount-nas-media.sh` | NFS mount attempts for the admin account | Self (emptied at each start); logrotate |
| `~admin/.local/state/com.<hostname>.mount-nas-media.log` | launchd, for the admin copy of `com.<hostname>.mount-nas-media` | stdout and stderr of the mount script | logrotate |

## Automatic update logs

| Path | Writer | Contents | Rotation |
| --- | --- | --- | --- |
| `~admin/.local/state/<hostname>-brew-upgrade.log` | `/usr/local/bin/<hostname>-brew-upgrade.sh` (daemon `com.<hostname>.brew-upgrade`) | Daily `brew update`, formula and cask upgrades, the stable-sign run, and `brew cleanup` | None in repo |
| `~admin/.local/state/<hostname>-brew-upgrade-stdout.log`, `<hostname>-brew-upgrade-stderr.log` | launchd, for `com.<hostname>.brew-upgrade` | stdout and stderr of the upgrade script | None in repo |
| `/var/log/<hostname>-softwareupdate.log` | `/usr/local/bin/<hostname>-softwareupdate.sh` (daemon `com.<hostname>.softwareupdate`) | Weekly `softwareupdate --download --all` output, and a note when updates wait for a manual install | None in repo |
| `/var/log/<hostname>-softwareupdate-stdout.log`, `<hostname>-softwareupdate-stderr.log` | launchd, for `com.<hostname>.softwareupdate` | stdout and stderr of the update script | None in repo |

## Operator account

| Path | Writer | Contents | Rotation |
| --- | --- | --- | --- |
| `~operator/.local/state/<hostname>-operator-login.log` | `operator-first-login.sh` | The one-time operator setup: Dock, terminal profile, iTerm2, logrotate | logrotate |
| `~operator/.local/state/<hostname>-operator-login-progress.log` | `operator-first-login.sh` | Short progress lines for the same run | None in repo |
| `~operator/.local/state/com.<hostname>.operator-first-login.log` | launchd, for `com.<hostname>.operator-first-login` | stdout and stderr of the first-login script | logrotate |
| `~operator/.local/state/<hostname>-mount.log` | `~operator/.local/bin/mount-nas-media.sh` | NFS mount attempts for the operator account | Self (emptied at each start); logrotate |
| `~operator/.local/state/com.<hostname>.mount-nas-media.log` | launchd, for the operator copy of `com.<hostname>.mount-nas-media` | stdout and stderr of the mount script | logrotate |
| `~operator/.local/state/msmtp.log` | `msmtp`, through the `logfile` line that `msmtp-setup.sh` writes | One line for each email that any watchdog or script sends, with the result | logrotate |

## Plex

| Path | Writer | Contents | Rotation |
| --- | --- | --- | --- |
| `~operator/.local/state/<hostname>-plex-launchagent.log` | launchd, for `com.<hostname>.plexmediaserver` | stdout and stderr of `start-plex.sh` | logrotate |
| `~operator/.local/state/plex-watchdog.log` | `plex-watchdog`, `plex-watchdog-ctl`, and launchd for `com.<hostname>.plex-watchdog` | Settings drift checks, liveness checks, and accept or revert actions | logrotate |
| `~operator/.local/state/tvmaze-scrobble.log` | `tvmaze-scrobble-listener`, `tvmaze-scrobble`, and launchd for `com.<hostname>.tvmaze-scrobble` and `com.<hostname>.tvmaze-reconcile` | Webhooks received, episodes matched and marked watched on TVmaze, hourly reconcile runs, and failures | logrotate |

## Transmission and FileBot

| Path | Writer | Contents | Rotation |
| --- | --- | --- | --- |
| `~operator/.local/state/<hostname>-podman-vm-stdout.log` | `podman-machine-start.sh` (stdout, through launchd for `com.<hostname>.podman-transmission-vm`) | The supervisor loop: VM and container starts, NFS waits, data-access checks, recoveries, podman timeouts | logrotate |
| `~operator/.local/state/<hostname>-podman-vm-stderr.log` | launchd, for `com.<hostname>.podman-transmission-vm` | stderr of the supervisor and of the podman commands it runs | logrotate |
| `~operator/.local/state/<hostname>-transmission-trigger-watcher.log` | `transmission-trigger-watcher.sh` | Trigger files found and the `transmission-done.sh` runs that they start | Self (5 MB cap) |
| `~operator/.local/state/<hostname>-trigger-watcher-stdout.log`, `<hostname>-trigger-watcher-stderr.log` | launchd, for `com.<hostname>.transmission-trigger-watcher` | stdout and stderr of the trigger watcher | None in repo |
| `~operator/.local/state/transmission-processing.log` | `transmission-done.sh` (path from `logging.file` in `config.yml`) | FileBot runs, matches, renames, Plex scans, and triage of files that could not be processed | Self (`logging.max_size`, default 10 MB) |
| `~operator/.local/state/<hostname>-pending-move-cleanup.log` | `pending-move-cleanup.sh`, and launchd for `com.<hostname>.pending-move-cleanup` | Folders removed from or kept in `pending-move/` | Self (5 MB cap) |
| `~operator/.local/state/<hostname>-pia-port-watchdog.log` | `pia-port-watchdog.sh`, and launchd for `com.<hostname>.pia-port-watchdog` | Port-forwarding checks and alert transitions | None in repo |
| `~operator/.local/state/<hostname>-stall-watchdog.log` | `stall-watchdog.sh`, and launchd for `com.<hostname>.stall-watchdog` | TCC prompt detection, long `transmission-done` runs, supervisor status checks, alert transitions | None in repo |

## Dropbox sync

| Path | Writer | Contents | Rotation |
| --- | --- | --- | --- |
| `~operator/.local/state/<hostname>-rclone.log` | `start-rclone.sh` | Each rclone sync run and its result | logrotate |
| `~operator/.local/state/com.<hostname>.dropbox-sync.log` | launchd, for `com.<hostname>.dropbox-sync` | stdout and stderr of `start-rclone.sh` | None in repo |

## Web front end and Cloudflare

| Path | Writer | Contents | Rotation |
| --- | --- | --- | --- |
| `/usr/local/var/log/caddy/access.log` | Caddy (the `access_log` snippet in the Caddyfile) | JSON access log for the LAN, external and tunnel sites | Caddy (rolls at 100 MB, keeps 10) |
| `~operator/.local/state/caddy/caddy.log` | launchd, for `com.caddyserver.caddy` (root) | Caddy stdout | None in repo |
| `~operator/.local/state/caddy/caddy-error.log` | launchd, for `com.caddyserver.caddy` (root) | Caddy stderr, where Caddy writes its runtime log, including certificate (ACME) messages | None in repo |
| `~operator/.local/state/caddy/media-server.log` | `media-server.py`, through launchd for `com.<hostname>.media-server` | The `/media` file server's start line and errors | None in repo |
| `~operator/.local/state/cloudflare-ddns.log` | `/usr/local/bin/cloudflare-ddns` (root), and launchd for `com.<hostname>.cloudflare-ddns` | Public IP checks, DNS record updates, heartbeats, Cloudflare API errors. The setup script creates the file owned by operator. | None in repo |
| `~operator/.local/state/cloudflared/cloudflared.log` | launchd, for `com.<hostname>.cloudflare-tunnel` (root) | `cloudflared` stdout | logrotate |
| `~operator/.local/state/cloudflared/cloudflared-error.log` | launchd, for `com.<hostname>.cloudflare-tunnel` (root) | `cloudflared` stderr, where it logs tunnel connections and errors. The tunnel watchdog reads it. | logrotate |
| `~operator/.local/state/tunnel-watchdog.log` | `tunnel-watchdog`, and launchd for `com.<hostname>.tunnel-watchdog` | `/ready` checks, failure streaks, alert transitions | logrotate |
| `~operator/.local/state/access-policy-watchdog.log` | `access-policy-watchdog`, and launchd for `com.<hostname>.access-policy-watchdog` | Access policy and tunnel config comparisons, drift alerts, API errors | logrotate |

## Related pages

- [LaunchAgents and LaunchDaemons](launchagents.md): the jobs that write the launchd logs above.
- [Monitoring](../apps/monitoring-README.md): how the watchdogs use these logs.
