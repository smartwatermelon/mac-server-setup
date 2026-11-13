# Scripts

This page lists every script in the repo's root, `app-setup/`, `app-setup/templates/`, and `scripts/`, derived from each file's header comment, its root check, and the setup script that deploys it.

"Runs as" is the account the script expects. "admin" means the admin account, with `sudo` prompts where a step needs root. "root" means that you start it with `sudo` or that launchd starts it as root. Links go to the file on GitHub.

## Repository root

| Path | Runs on | Runs as | Purpose |
| --- | --- | --- | --- |
| [`prep-airdrop.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/prep-airdrop.sh) | Dev Mac | Your user | Builds the setup package: gets credentials from 1Password, writes the hardware fingerprint, Wi-Fi strategy and manifest, and copies the scripts to `~/<hostname>-setup` |
| [`run_tests.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/run_tests.sh) | Dev Mac | Your user | Runs the BATS unit and integration tests |

## scripts/airdrop

| Path | Runs on | Runs as | Purpose |
| --- | --- | --- | --- |
| [`scripts/airdrop/rclone-airdrop-prep.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/airdrop/rclone-airdrop-prep.sh) | Dev Mac | Your user | Installs rclone, runs the Dropbox OAuth sign-in, and adds the rclone config to the setup package. `prep-airdrop.sh` calls it. |

## scripts/docs

| Path | Runs on | Runs as | Purpose |
| --- | --- | --- | --- |
| `scripts/docs/gen-config-reference.sh` | Dev Mac or CI | Your user | Writes [config keys](config-keys.md) from `config/config.conf.template`. `--check` exits 1 if the page is stale. |

## scripts/server

These scripts are copied into the setup package. `first-boot.sh` calls the `setup-*.sh` modules in order. You can run a module again by itself.

| Path | Runs on | Runs as | Purpose |
| --- | --- | --- | --- |
| [`first-boot.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/first-boot.sh) | Server | admin | System provisioning: fingerprint check, FileVault check, then each setup module |
| [`setup-apple-id.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-apple-id.sh) | Server | admin | Apple Account sign-in and iCloud settings |
| [`setup-application-preparation.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-application-preparation.sh) | Server | admin | Copies the app-setup folder and operator files into place, and installs the operator first-login LaunchAgent |
| [`setup-auto-updates.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-auto-updates.sh) | Server | admin (refuses root) | Daily Homebrew upgrade daemon, stable signing, App Store auto-update, and the weekly download-only macOS update daemon |
| [`setup-bash-configuration.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-bash-configuration.sh) | Server | admin | Bash configuration for the admin and operator accounts |
| [`setup-command-line-tools.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-command-line-tools.sh) | Server | admin | Installs the Xcode Command Line Tools and reports progress |
| [`setup-dock-configuration.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-dock-configuration.sh) | Server | admin | Removes default Dock apps and adds utilities, with `dockutil` |
| [`setup-firewall.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-firewall.sh) | Server | admin | Turns on the application firewall and allows SSH |
| [`setup-hostname-volume.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-hostname-volume.sh) | Server | admin | Sets the computer name and local host name, and renames the system volume to match |
| [`setup-log-rotation.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-log-rotation.sh) | Server | admin | Installs `logrotate.conf` and starts the Homebrew logrotate service |
| [`setup-package-installation.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-package-installation.sh) | Server | admin | Installs Homebrew and the formulae and casks from `config/formulae.txt` and `config/casks.txt` |
| [`setup-power-management.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-power-management.sh) | Server | admin | Turns off system sleep, sets display sleep, turns on wake for network access and restart after power failure |
| [`setup-remote-desktop.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-remote-desktop.sh) | Server | admin (refuses root) | Turns off Screen Sharing and Remote Management, then guides you to turn Screen Sharing on by hand |
| [`setup-shell-configuration.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-shell-configuration.sh) | Server | admin | Makes Homebrew bash the login shell for the admin and operator accounts |
| [`setup-ssh-access.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-ssh-access.sh) | Server | admin | Turns on Remote Login (SSH) and installs SSH keys for the admin and operator accounts |
| [`setup-system-preferences.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-system-preferences.sh) | Server | admin | System preferences, such as Fast User Switching |
| [`setup-terminal-profiles.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-terminal-profiles.sh) | Server | admin | Imports terminal profiles and makes them the default for the admin and operator accounts |
| [`setup-timemachine.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-timemachine.sh) | Server | admin | Sets the Time Machine SMB destination from keychain credentials |
| [`setup-touchid-sudo.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-touchid-sudo.sh) | Server | admin | Turns on Touch ID for `sudo` and sets a temporary `sudo` timeout for setup |
| [`setup-wifi-network.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/setup-wifi-network.sh) | Server | admin | Checks and configures Wi-Fi, stores the password in the keychain, and tests the connection |
| [`operator-first-login.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/scripts/server/operator-first-login.sh) | Server | operator | One-time operator setup at first login: Dock, terminal profile, iTerm2, logrotate. Its LaunchAgent starts it. |

## app-setup

`run-app-setup.sh` runs the setup scripts in dependency order. The scripts that refuse to run without root say so in the "Runs as" column.

| Path | Runs on | Runs as | Purpose |
| --- | --- | --- | --- |
| [`run-app-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/run-app-setup.sh) | Server | admin | Runs the app-setup scripts in dependency order. `--only SCRIPT` runs one. |
| [`rclone-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/rclone-setup.sh) | Server | admin | Installs the rclone config for operator and the Dropbox sync LaunchAgent |
| [`podman-transmission-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/podman-transmission-setup.sh) | Server | admin | Installs Podman, creates the `transmission-vm` machine, deploys the Transmission and PIA VPN container, the trigger watcher, the cleanup timer and the watchdogs |
| [`filebot-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/filebot-setup.sh) | Server | admin | Installs FileBot, applies the license, and sets the rename formats and OpenSubtitles login |
| [`transmission-filebot-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/transmission-filebot-setup.sh) | Server | The account that runs the pipeline | Interactive wizard: asks for the Plex server and token, writes `~/.config/transmission-done/config.yml`, and links `~/.local/bin/transmission-done` |
| [`catch-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/catch-setup.sh) | Server | admin | Installs Catch, sets its feed and save folder, and adds its LaunchAgent for operator |
| [`plex-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/plex-setup.sh) | Server | admin | NFS mount agents for the NAS media share, Plex install, optional migration from an earlier server, and the Plex LaunchAgent |
| [`plex-watchdog-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/plex-watchdog-setup.sh) | Server | admin | Deploys the Plex settings watchdog, `plex-watchdog-ctl`, the golden config and the LaunchAgent |
| [`msmtp-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/msmtp-setup.sh) | Server | admin | Configures msmtp for operator as the shared alert email relay, and sends a test email |
| [`caddy-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/caddy-setup.sh) | Server | root | Deploys the Caddyfile, web files, Caddy wrapper, media file server and their LaunchDaemons |
| [`cloudflare-ddns-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/cloudflare-ddns-setup.sh) | Server | root | Deploys the Cloudflare DDNS updater and its LaunchDaemon |
| [`cloudflared-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/cloudflared-setup.sh) | Server | root | Deploys the Cloudflare Tunnel wrapper and its LaunchDaemon |
| [`access-policy-watchdog-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/access-policy-watchdog-setup.sh) | Server | root | Deploys the Access policy drift watchdog as an operator LaunchAgent |
| [`tunnel-watchdog-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/tunnel-watchdog-setup.sh) | Server | root | Deploys the tunnel health watchdog as an operator LaunchAgent |
| [`tvmaze-scrobble-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/tvmaze-scrobble-setup.sh) | Server | root | Deploys the Plex to TVmaze listener, worker, credentials and two operator LaunchAgents |

## app-setup/templates

The setup scripts copy these files to the server and fill in their `__PLACEHOLDER__` tokens. "Sourced" means that the file defines functions for another script and runs nothing by itself.

| Path | Runs on | Runs as | Purpose |
| --- | --- | --- | --- |
| [`access-policy-watchdog.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/access-policy-watchdog.sh) | Server | operator | Emails when the Cloudflare Access policy or tunnel config changes. `--check` prints the result only. |
| [`alert-lib.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/alert-lib.sh) | Server | operator (sourced) | Shared alert email and JSON state helpers for the watchdogs |
| [`caddy-health.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/caddy-health.sh) | Server | Any account, by hand | Tests the Caddy endpoints and the certificate, and reports the status |
| [`caddy-wrapper.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/caddy-wrapper.sh) | Server | root (LaunchDaemon) | Reads `CF_API_TOKEN` from the System keychain, then starts Caddy |
| [`cloudflare-ddns.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/cloudflare-ddns.sh) | Server | root (LaunchDaemon) | Compares the public IP with the DNS A record and updates the record when they differ |
| [`cloudflared-wrapper.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/cloudflared-wrapper.sh) | Server | root (LaunchDaemon) | Reads the tunnel token from the System keychain into `TUNNEL_TOKEN`, then starts `cloudflared` |
| [`media-compare.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/media-compare.sh) | Server | operator (sourced) | Decides which of two copies of the same media to keep when FileBot renames onto an existing file |
| [`mount-nas-media.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/mount-nas-media.sh) | Server | admin and operator (LaunchAgent) | Mounts the NAS media share over NFS for one account |
| [`pending-move-cleanup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/pending-move-cleanup.sh) | Server | operator (LaunchAgent) | Removes processed folders from Transmission's `pending-move/` folder |
| [`pia-pf-probe.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/pia-pf-probe.sh) | Server | operator, by hand | Tests PIA regions for working port forwarding in a separate container, and writes CSV results |
| [`pia-port-guard.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/pia-port-guard.sh) | Transmission container | Container (sourced) | Validates a PIA forwarded port before it is applied |
| [`pia-port-watchdog.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/pia-port-watchdog.sh) | Server | operator (LaunchAgent) | Alerts when PIA port forwarding is lost |
| [`plex-watchdog-ctl.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/plex-watchdog-ctl.sh) | Server | operator, by hand | Shows, accepts or reverts Plex settings drift (`status`, `accept`, `revert`) |
| [`plex-watchdog.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/plex-watchdog.sh) | Server | operator (LaunchAgent) | Compares Plex preferences with the golden config, checks that Plex is alive, and emails on drift |
| [`stable-sign.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/stable-sign.sh) | Server | admin (from the brew upgrade daemon, or by hand) | Keeps signed copies of Homebrew binaries at fixed paths under `/usr/local/stable`, so TCC grants survive `brew upgrade`. `--check` verifies them. |
| [`stall-watchdog.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/stall-watchdog.sh) | Server | operator (LaunchAgent) | Alerts when the server is blocked: an open TCC prompt, a long `transmission-done` run, or a failing or quiet supervisor |
| [`start-plex.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/start-plex.sh) | Server | operator (LaunchAgent) | Starts Plex Media Server |
| [`start-rclone.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/start-rclone.sh) | Server | operator (LaunchAgent) | Syncs a Dropbox folder to the local disk with rclone at a fixed interval |
| [`transmission-done.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/transmission-done.sh) | Server | operator (from the trigger watcher) | Processes a completed download: runs FileBot, files the result in the media library, and asks Plex to scan |
| [`transmission-post-done.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/transmission-post-done.sh) | Transmission container | Container | Writes a trigger file when a torrent finishes, for the host trigger watcher |
| [`transmission-post-start.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/transmission-post-start.sh) | Transmission container | Container | Gets a PIA forwarded port, validates it, and applies it to Transmission. Replaces the image's own port updater. |
| [`transmission-trigger-watcher.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/transmission-trigger-watcher.sh) | Server | operator (LaunchAgent) | Polls for trigger files from the container, maps the container path to the host path, and runs `transmission-done.sh` |
| [`tunnel-watchdog.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/tunnel-watchdog.sh) | Server | operator (LaunchAgent) | Emails when the Cloudflare Tunnel is down. `--check` prints the result only. |
| [`tvmaze-scrobble.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/tvmaze-scrobble.sh) | Server | operator (LaunchAgent) | Marks a Plex TV episode watched on TVmaze. `--reconcile` syncs missed plays. |
| [`media-server.py`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/media-server.py) | Server | operator (LaunchDaemon) | Serves directory listings and files from the NFS media mount on loopback, for Caddy's `/media/` route |
| [`tvmaze-scrobble-listener.py`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/tvmaze-scrobble-listener.py) | Server | operator (LaunchAgent) | Receives Plex webhooks on loopback and hands each one to `tvmaze-scrobble` |
| [`process-media.command`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/templates/process-media.command) | Server | operator, by hand | Runs `transmission-done.sh` from its folder in a Terminal window and shows the result |

## Related pages

- [LaunchAgents and LaunchDaemons](launchagents.md): which jobs start these scripts.
- [Logs](logs.md): where each script writes.
