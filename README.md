# Mac Mini Server Setup

Automated setup for an Apple Silicon Mac Mini as a home server. Plex, Transmission over VPN, RSS show tracking, Dropbox sync, the whole deal.

## TL;DR

**What this does**: Takes a fresh Mac Mini and turns it into a media server with Plex, VPN-protected torrents, automatic show downloads, backups, and remote access.

**Prerequisites** (5 minutes):

1. Install 1Password CLI: `brew install 1password-cli && op signin`
2. Generate SSH keys: `ssh-keygen -t ed25519`
3. Copy `config/config.conf.template` to `config/config.conf` and set your `SERVER_NAME`
4. Create these 1Password items: "operator", "TimeMachine", "Plex NAS", "Apple", "OpenSubtitles"

**Setup** (15-30 minutes):

1. **On dev Mac**: `./prep-airdrop.sh` (builds deployment package)
2. **AirDrop** the generated folder to your Mac Mini
3. **On Mac Mini desktop** (not SSH): `cd ~/Downloads/macmini-setup && ./first-boot.sh`
4. **Run app setup**: when `first-boot.sh` finishes it opens a Terminal window in `~/app-setup`. Run `./run-app-setup.sh` there, as the admin user. It doesn't run by itself.
5. **Reboot**. The Mac logs in as operator, and a one-time LaunchAgent finishes the operator account.

**Result**: Server at `your-server-name.local`, everything running.

More detail in [Prerequisites](docs/prerequisites.md) and [Configuration Keys](docs/reference/config-keys.md).

Adapting this to your own setup? The [stack matrix](docs/stack-matrix.md) lists which parts are required, optional or replaceable.

## What's running

After setup, these all start automatically on login (LaunchAgents):

| Service | What it does |
|---------|-------------|
| Plex Media Server | Streams media to any device |
| Podman + Transmission | Containerized BitTorrent client with VPN enforced at the kernel level |
| Catch | Polls ShowRSS feed, grabs new episodes |
| FileBot | Renames and sorts downloads into the Plex library |
| rclone | Syncs Dropbox torrent files to the Transmission watch directory |
| NAS Mount | NFS mount to NAS on login |
| Backblaze | Off-site backup |
| Caddy | Reverse proxy with internal TLS and external HTTPS |
| Cloudflare DDNS | Keeps `vpn.example.com` (home VPN) in sync with the WAN IP |
| Plex Watchdog | Monitors Plex settings against golden config, emails on drift |

### Media pipeline

How a new episode gets from RSS to your TV:

```text
ShowRSS feed
  -> Catch (polls the RSS feed, downloads .torrent files)
  -> Dropbox (rclone syncs torrent files to the server)
  -> Transmission (imports from watch folder, downloads over VPN)
  -> transmission-done.sh (FileBot renames + moves to library)
  -> Plex (detects new media, serves to your devices)
```

### VPN protection

Transmission runs inside a Podman container with OpenVPN enforced at the kernel level (haugene/transmission-openvpn). The container cannot route traffic outside the VPN tunnel — no kill switch scripts needed, no monitoring daemons, no PIA Desktop app. If the VPN drops, the container has no network.

## How it works

Three phases, two machines.

**Phase 1** (`prep-airdrop.sh`, on your dev Mac): Pulls credentials from 1Password, creates a hardware-locked keychain, copies SSH keys and configs, runs the rclone OAuth dance, packages it all into a folder.

**Phase 2** (`first-boot.sh`, on the Mac Mini): Validates the hardware fingerprint, imports the keychain, creates the operator user account with auto-login, runs 19 setup modules (SSH, Homebrew, FileVault, Time Machine, etc). Has to be run from the local desktop, not SSH.

**Phase 3** (`run-app-setup.sh`, on the Mac Mini): Discovers and runs all `*-setup.sh` scripts in dependency order: rclone, transmission, filebot, catch, plex, caddy. Each one installs the app, sets preferences, creates a LaunchAgent or LaunchDaemon, and deploys template files with placeholder substitution.

### Configuration flow

One config file runs the show:

```text
config/config.conf
  ├── prep-airdrop.sh reads it     (Phase 1)
  ├── first-boot.sh sources it     (Phase 2)
  └── run-app-setup.sh sources it  (Phase 3)
```

Key variables: `SERVER_NAME`, `OPERATOR_USERNAME`, `NAS_HOSTNAME`, `NAS_SHARE_NAME`, `NAS_VOLUME`, `ONEPASSWORD_VAULT`.

### Credentials

No plaintext secrets in the deployment package:

```text
1Password (dev Mac)
  -> prep-airdrop.sh retrieves via `op` CLI
  -> Stored in external keychain (password = hardware UUID)
  -> AirDropped as .keychain-db file

first-boot.sh (Mac Mini)
  -> Imports external keychain
  -> Extracts credentials to system/login keychain
  -> Scripts read via `security find-generic-password`
```

1Password is dev-machine only. The server never needs it.

## Design choices

Native macOS apps where possible, containers where isolation matters. Transmission runs in a Podman VM for VPN enforcement; everything else is native. All configuration happens under the admin account; the operator logs in to a working system and doesn't need to touch anything.

Every script is idempotent (safe to re-run). Errors display immediately during setup and again in a summary at the end, so nothing gets buried in scroll.

## Prerequisites

- Apple Silicon Mac Mini with a fresh macOS install
- Development Mac with:
  - 1Password CLI (`brew install 1password-cli && op signin`)
  - SSH keys (`~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`)
  - 1Password vault items: operator, TimeMachine, Plex NAS, Apple ID, OpenSubtitles
  - `jq` and `openssl` (both pre-installed on macOS)
  - `config/config.conf` created from the template

See [Prerequisites Guide](docs/prerequisites.md) for validation commands.

> Tested on macOS 15.x, Apple Silicon only. Might work on Intel or older macOS but I haven't tried.

## Setup

1. **Build the deployment package** on your dev Mac:

   ```bash
   ./prep-airdrop.sh
   ```

   Pulls credentials from 1Password, builds a hardware-locked keychain, processes config templates, generates a deployment manifest.

2. **AirDrop the folder** to your Mac Mini.

   > [airdrop-cli](https://github.com/vldmrkl/airdrop-cli) lets you do this from the terminal:
   > `brew install --HEAD vldmrkl/formulae/airdrop-cli`

3. **Run first-boot** on the Mac Mini (local desktop session, not SSH):

   ```bash
   cd ~/Downloads/macmini-setup  # <server name, lowercase>-setup
   ./first-boot.sh
   ```

   > This needs the local desktop for System Settings dialogs and FileVault management. It will not work over SSH.

4. **Run the app setup by hand.** When `first-boot.sh` finishes, it opens a Terminal window in `~/app-setup`. Run `./run-app-setup.sh` there, as the admin user. Add `--continue-on-error` to keep going past a failed script, or `--only <script>` to run one script.

5. **Reboot.** The Mac logs in as operator automatically. A one-time LaunchAgent (`operator-first-login.sh`) finishes the operator account. It doesn't install apps.

## File structure

```plaintext
.
├── prep-airdrop.sh                # Entry point: builds deployment package
├── app-setup/                     # Application setup scripts
│   ├── run-app-setup.sh          # Orchestrator (runs scripts in dependency order)
│   ├── caddy-setup.sh            # Caddy reverse proxy deployment
│   ├── cloudflare-ddns-setup.sh  # Cloudflare A-record DDNS updater
│   ├── catch-setup.sh            # RSS feed monitor (ShowRSS)
│   ├── filebot-setup.sh          # Media renaming and sorting
│   ├── msmtp-setup.sh            # Shared email facility (Gmail SMTP)
│   ├── plex-setup.sh             # Plex Media Server (with migration support)
│   ├── plex-watchdog-setup.sh    # Plex settings drift monitor
│   ├── podman-transmission-setup.sh  # Containerized Transmission + VPN
│   ├── rclone-setup.sh           # Dropbox sync to watch directory
│   ├── transmission-filebot-setup.sh  # Media processing pipeline config wizard
│   └── templates/                # Runtime script templates
│       ├── Caddyfile              # Caddy reverse proxy config
│       ├── caddy-wrapper.sh       # CF_API_TOKEN injection wrapper
│       ├── caddy-health.sh        # Caddy endpoint health checker
│       ├── media-server.py        # Python file server for NFS media
│       ├── com.caddyserver.caddy.plist  # Caddy LaunchDaemon
│       ├── com.cloudflare-ddns.plist    # Cloudflare DDNS LaunchDaemon
│       ├── cloudflare-ddns.sh           # Cloudflare DDNS updater script
│       ├── com.media-server.plist       # Media server LaunchDaemon
│       ├── config.yml.template    # Transmission-FileBot pipeline config
│       ├── mount-nas-media.sh     # NFS mount script
│       ├── process-media.command  # Manual media processing wrapper
│       ├── start-plex.sh         # Plex startup wrapper
│       ├── start-rclone.sh       # rclone sync script
│       ├── plex-golden.conf.template   # Plex settings golden config template
│       ├── plex-watchdog.sh           # Plex settings poll daemon
│       ├── plex-watchdog-ctl.sh       # Plex watchdog CLI (status/accept/revert)
│       ├── transmission-done.sh       # Media processing: rename, sort, Plex scan
│       ├── transmission-post-done.sh  # Container-side completion trigger
│       ├── transmission-trigger-watcher.sh  # Host-side trigger → FileBot
│       └── www/                   # Caddy dashboard static assets
├── scripts/
│   ├── airdrop/
│   │   └── rclone-airdrop-prep.sh  # Dropbox OAuth for AirDrop
│   └── server/
│       ├── first-boot.sh          # Main provisioning script (19 modules)
│       ├── operator-first-login.sh # Operator customization (LaunchAgent)
│       ├── setup-apple-id.sh
│       ├── setup-application-preparation.sh
│       ├── setup-auto-updates.sh  # Homebrew/MAS/macOS auto-updates
│       ├── setup-bash-configuration.sh
│       ├── setup-command-line-tools.sh
│       ├── setup-dock-configuration.sh
│       ├── setup-firewall.sh
│       ├── setup-hostname-volume.sh
│       ├── setup-log-rotation.sh
│       ├── setup-package-installation.sh
│       ├── setup-power-management.sh
│       ├── setup-remote-desktop.sh
│       ├── setup-shell-configuration.sh
│       ├── setup-ssh-access.sh
│       ├── setup-system-preferences.sh
│       ├── setup-terminal-profiles.sh
│       ├── setup-timemachine.sh
│       ├── setup-touchid-sudo.sh
│       └── setup-wifi-network.sh
├── config/
│   ├── config.conf.template      # Configuration template
│   ├── config.conf               # Your active configuration
│   ├── formulae.txt              # Homebrew CLI packages
│   ├── casks.txt                 # Homebrew GUI applications
│   ├── logrotate.conf            # Log rotation rules
│   ├── com.googlecode.iterm2.plist  # iTerm2 profile
│   └── Orangebrew.terminal       # Terminal.app profile
└── docs/                         # The docs site: https://smartwatermelon.github.io/mac-server-setup/
    ├── index.md                  # Landing page
    ├── *.md                      # Other pages: prerequisites, configuration, operator, ...
    ├── get-started/              # Tutorial, start to finish
    ├── components/               # One page per component
    ├── reference/                # Config keys, LaunchAgents, logs, ports, scripts
    ├── explanation/              # Design decisions
    ├── troubleshooting/          # Symptom, cause, fix
    ├── setup/firstboot-README.md # Copied into the setup package by prep-airdrop.sh
    ├── plans/                    # Design plans (history)
    └── archive/                  # Retired write-ups (history)
```

## Configuration

Everything lives in `config/config.conf`:

```bash
SERVER_NAME="YOUR_SERVER_NAME"
OPERATOR_USERNAME="operator"
NAS_HOSTNAME="your-nas.local"
NAS_SHARE_NAME="Media"
# 1Password vault "Private", by ID so a rename cannot break it.
OP_VAULT_ID="your-vault-id"
ONEPASSWORD_VAULT="${OP_VAULT_ID}"
ONEPASSWORD_OPERATOR_ITEM="server operator"
ONEPASSWORD_TIMEMACHINE_ITEM="TimeMachine"
ONEPASSWORD_APPLEID_ITEM="Apple"
MONITORING_EMAIL="your-email@example.com"
```

## Security

SSH is key-only (password login disabled). The admin account gets TouchID sudo. A separate operator account with automatic login handles day-to-day use.

Firewall is on with an SSH allowlist. Transmission traffic is VPN-bound and never touches the real IP. Credentials travel in a hardware-locked keychain, not plaintext. The setup script checks the hardware fingerprint and refuses to run on the wrong machine. The Mac restarts automatically after power failure.

## Error handling

Errors show up immediately during setup and again in a summary at the end:

```bash
====== SETUP SUMMARY ======
Setup completed, but 1 error and 2 warnings occurred:

ERRORS:
  x Installing Homebrew Packages: Formula installation failed: some-package

WARNINGS:
  ! Copying SSH Keys: SSH private key not found at ~/.ssh/id_ed25519
  ! WiFi Network Configuration: Could not detect current WiFi network

Review the full log for details: ~/.local/state/macmini-setup.log
```

Errors block setup. Warnings are optional stuff that wasn't available (SSH keys you didn't generate, WiFi you're not connected to). Each message tags which setup section it came from.

## Logs

| Script | Log location |
|--------|-------------|
| `prep-airdrop.sh` | Console output only |
| `first-boot.sh` | `~/.local/state/<hostname>-setup.log` |
| App setup scripts | `~/.local/state/<hostname>-app-setup.log` |
| NFS mount | `~/.local/state/<hostname>-mount.log` |
| Operator login | `~/.local/state/<hostname>-operator-login.log` |
| Plex watchdog | `~/.local/state/plex-watchdog.log` |
| msmtp (email) | `~/.local/state/msmtp.log` |
| Media processing | `~/.local/state/transmission-processing.log` |
| Caddy access | `/usr/local/var/log/caddy/access.log` |
| Caddy errors | `~/.local/state/caddy/caddy-error.log` |
| Media file server | `~/.local/state/caddy/media-server.log` |

## Troubleshooting

**"GUI session required"**: You're running over SSH. `first-boot.sh` needs the local desktop. Check: `launchctl managername` should say `Aqua`, not `Background`.

**SSH access denied**: SSH keys didn't make it into the deployment package, or SSH isn't enabled on the target.

**TouchID not working for operator**: By design. TouchID and automatic login are mutually exclusive on macOS. The admin account has TouchID; the operator account has auto-login.

**Passwords app rejects the operator password after a reboot**: Known limitation of auto-login. In a session that auto-login started, the Passwords app rejects the correct password (the field shakes). Log out of the operator account and log back in by typing the password; Passwords then unlocks. Check the SecureToken first: `sysadminctl -secureTokenStatus operator` must say `ENABLED` (`first-boot.sh` grants it). Confirmed on 2026-11-05, see [#231](https://github.com/smartwatermelon/mac-server-setup/issues/231).

**Homebrew not found**: Restart Terminal or `source ~/.bash_profile`.

**1Password items not found**: Vault name and item titles in `config.conf` have to match exactly.

**Transmission container not starting**: Check `podman machine list` and `podman logs transmission-vpn`. If the VPN can't connect, verify PIA credentials in the keychain. The container has a health check that restarts it after 3 minutes of unresponsiveness. The supervisor LaunchAgent (`podman-machine-start.sh`) checks the VM and container every 5 minutes. Its log is `~/.local/state/<hostname>-podman-vm-stdout.log` in the operator account, and its last result is in `~/.local/state/<hostname>-supervisor-status.json`. Check health status with `sudo -u operator -i bash -c 'podman inspect transmission-vpn --format "{{.State.Health.Status}}"'`.

**Transmission "Permission denied" adding torrents**: The container's `/data` usually can't reach the NAS. `/data` is the host's NFS mount, passed into the Podman VM over VirtioFS. There's no NFS mount inside the VM. Check the host mount first, with `mount | grep /Users/operator/.local/mnt`. The mount log is `~/.local/state/<hostname>-mount.log` in the operator account. Next, check the container with `sudo -u operator -i bash -c 'podman exec transmission-vpn ls /data/'`. The supervisor runs the same check. After 3 failures in a row it cycles the VM to refresh the VirtioFS handles. Let the supervisor do that rather than starting the VM from a shell. [Monitoring](docs/components/monitoring.md) covers the supervisor. Never unmount the host NFS share: Plex reads from it.

**Plex watchdog not running**: The LaunchAgent only runs in GUI sessions. Verify with `sudo launchctl print gui/$(id -u operator)/com.<hostname>.plex-watchdog`. Check status with `sudo -iu operator plex-watchdog-ctl status`. If it's not loaded, bootstrap it: `sudo launchctl bootstrap gui/$(id -u operator) /Users/operator/Library/LaunchAgents/com.<hostname>.plex-watchdog.plist`.

**App not starting on login**: `launchctl list | grep <app>` to check status. Also check `/Users/Shared/` directory permissions.

## Docs

| Topic | Link |
|-------|------|
| What you need before starting | [Prerequisites](docs/prerequisites.md) |
| Configuration options | [Configuration Keys](docs/reference/config-keys.md) |
| Customizing parameters | [Configure](docs/get-started/03-configure.md) |
| Building the deployment package | [Prep-AirDrop](docs/get-started/prep-airdrop.md) |
| Running system provisioning | [First Boot](docs/get-started/first-boot.md) |
| Post-reboot setup | [Operator Setup](docs/operator.md) |
| How credentials move between machines | [Keychain Management](docs/keychain-credential-management.md) |
| Plex settings watchdog | [Plex Watchdog](docs/components/plex-watchdog.md) |
| Caddy reverse proxy | [Caddy README](docs/components/caddy.md) |
| Home VPN (Synology NAS + Tunnelblick) | [Home VPN](docs/components/home-vpn.md) |
| Media processing pipeline | [Transmission-FileBot](docs/components/transmission-filebot.md) |

## Testing

141 BATS tests cover the media processing pipeline and Plex watchdog:

```bash
# Run all tests
bats tests/plex-watchdog.bats
bats tests/transmission-filebot/unit/*.bats tests/transmission-filebot/integration/*.bats

# Or use the test runner
./run_tests.sh
```

Tests run automatically in CI on every push and PR.

## Contributing

Scripts must be idempotent (re-runnable without breaking things). Use `log()`/`show_log()` for output. Use `collect_error()` for blockers, `collect_warning()` for optional stuff, `set_section()` so errors have context. Update docs when you change config. `shellcheck` must pass clean, no exceptions.

## License

MIT; see [LICENSE](LICENSE.md)
