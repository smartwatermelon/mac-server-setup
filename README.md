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
3. **On Mac Mini desktop** (not SSH): `cd ~/Downloads/MACMINI-setup && ./first-boot.sh`
4. **Reboot** and log in as operator for automatic final setup

**Result**: Server at `your-server-name.local`, everything running.

More detail in [Prerequisites](docs/prerequisites.md) and [Environment Variables](docs/environment-variables.md).

## What's running

After setup, these all start automatically on login (LaunchAgents):

| Service | What it does |
|---------|-------------|
| Plex Media Server | Streams media to any device |
| Transmission | BitTorrent client, bound to VPN |
| Catch | Polls ShowRSS feed, grabs new episodes |
| FileBot | Renames and sorts downloads into the Plex library |
| rclone | Bidirectional Dropbox sync for torrent file delivery |
| VPN Monitor | Kills Transmission within 5s if VPN drops, restarts when it's back |
| PIA Monitor | Detects PIA split tunnel config drift, restores settings |
| Plex VPN Bypass | PF rules so Plex stays reachable through the VPN |
| NAS Mount | SMB mount to NAS on login |
| Backblaze | Off-site backup |
| Caddy | Local web server |

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

Transmission never touches your real IP. Multiple layers back each other up:

| Layer | What it does |
|-------|-------------|
| PIA split-tunnel inversion | All traffic goes through VPN; only Plex/Backblaze/Safari bypass |
| PIA config watchdog | PIA has a habit of forgetting its split tunnel config. This catches that. |
| VPN monitor | Polls every 5s, kills Transmission if VPN drops, restarts when it's back |
| Plex VPN bypass | PF `route-to` rules so Plex stays reachable on your public IP |
| Auto-updates | Homebrew daily at 04:30, MAS via macOS, softwareupdate download-only |

More in [VPN Architecture](docs/vpn-transmission.md).

## How it works

Three phases, two machines.

**Phase 1** (`prep-airdrop.sh`, on your dev Mac): Pulls credentials from 1Password, creates a hardware-locked keychain, copies SSH keys and configs, runs the rclone OAuth dance, packages it all into a folder.

**Phase 2** (`first-boot.sh`, on the Mac Mini): Validates the hardware fingerprint, imports the keychain, creates the operator user account with auto-login, runs 19 setup modules (SSH, Homebrew, FileVault, Time Machine, etc). Has to be run from the local desktop, not SSH.

**Phase 3** (`run-app-setup.sh`, on the Mac Mini): Discovers and runs all `*-setup.sh` scripts in dependency order: rclone, transmission, filebot, catch, plex. Each one installs the app, sets preferences, creates a LaunchAgent.

### Configuration flow

One config file runs the show:

```text
config/config.conf
  ├── prep-airdrop.sh reads it     (Phase 1)
  ├── first-boot.sh sources it     (Phase 2)
  └── run-app-setup.sh sources it  (Phase 3)
```

Key variables: `SERVER_NAME`, `OPERATOR_USERNAME`, `NAS_HOSTNAME`, `NAS_SHARE_NAME`, `ONEPASSWORD_VAULT`.

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

No Docker. Native macOS apps get hardware acceleration and don't fight the OS on mounts and permissions. All configuration happens under the admin account; the operator logs in to a working system and doesn't need to touch anything.

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
   cd ~/Downloads/MACMINI-setup  # default name
   ./first-boot.sh
   ```

   > This needs the local desktop for System Settings dialogs and FileVault management. It will not work over SSH.

4. **Reboot and log in as operator.** The rest happens automatically via LaunchAgent.

## File structure

```plaintext
.
├── prep-airdrop.sh                # Entry point: builds deployment package
├── app-setup/                     # Application setup scripts
│   ├── run-app-setup.sh          # Orchestrator (runs scripts in dependency order)
│   ├── catch-setup.sh            # RSS feed monitor (ShowRSS)
│   ├── filebot-setup.sh          # Media renaming and sorting
│   ├── plex-setup.sh             # Plex Media Server (with migration support)
│   ├── rclone-setup.sh           # Dropbox bidirectional sync
│   ├── transmission-setup.sh     # BitTorrent client with GUI automation
│   └── templates/                # Runtime script templates
│       ├── mount-nas-media.sh    # SMB mount script
│       ├── start-plex.sh         # Plex startup wrapper
│       ├── start-rclone.sh       # rclone sync script
│       ├── transmission-done.sh  # Download completion handler (FileBot)
│       ├── transmission-done-template.sh  # Completion script template
│       ├── vpn-monitor.sh        # VPN drop detection daemon
│       ├── pia-split-tunnel-monitor.sh    # PIA config watchdog
│       └── plex-vpn-bypass.sh    # PF rules for Plex reachability
├── scripts/
│   ├── airdrop/
│   │   └── rclone-airdrop-prep.sh  # Dropbox OAuth for AirDrop
│   └── server/
│       ├── first-boot.sh          # Main provisioning script (19 modules)
│       ├── operator-first-login.sh # Operator customization (LaunchAgent)
│       ├── pf-test-user.sh        # PF user-keyword test utility
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
│       ├── setup-vpn-killswitch.sh  # VPN protection setup
│       └── setup-wifi-network.sh
├── config/
│   ├── config.conf.template      # Configuration template
│   ├── config.conf               # Your active configuration
│   ├── formulae.txt              # Homebrew CLI packages
│   ├── casks.txt                 # Homebrew GUI applications
│   ├── logrotate.conf            # Log rotation rules
│   ├── com.googlecode.iterm2.plist  # iTerm2 profile
│   └── Orangebrew.terminal       # Terminal.app profile
└── docs/
    ├── prerequisites.md          # Setup requirements
    ├── environment-variables.md  # Configuration reference
    ├── configuration.md          # Customization guide
    ├── operator.md               # Post-reboot operator setup
    ├── vpn-transmission.md       # VPN architecture details
    ├── pia-split-tunnel-bug.md   # PIA bug documentation
    ├── keychain-credential-management.md  # Credential system
    ├── setup/
    │   ├── prep-airdrop.md       # Package preparation details
    │   ├── first-boot.md         # Provisioning details
    │   └── apple-first-boot-dialogs.md  # macOS setup wizard notes
    └── apps/
        ├── plex-setup-README.md
        ├── rclone-setup-README.md
        └── transmission-setup-README.md
```

## Configuration

Everything lives in `config/config.conf`:

```bash
SERVER_NAME="YOUR_SERVER_NAME"
OPERATOR_USERNAME="operator"
NAS_HOSTNAME="your-nas.local"
NAS_SHARE_NAME="DSMedia"
ONEPASSWORD_VAULT="personal"
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
| SMB mount | `~/.local/state/<hostname>-mount.log` |
| Operator login | `~/.local/state/<hostname>-operator-login.log` |

## Troubleshooting

**"GUI session required"**: You're running over SSH. `first-boot.sh` needs the local desktop. Check: `launchctl managername` should say `Aqua`, not `Background`.

**SSH access denied**: SSH keys didn't make it into the deployment package, or SSH isn't enabled on the target.

**TouchID not working for operator**: By design. TouchID and automatic login are mutually exclusive on macOS. The admin account has TouchID; the operator account has auto-login.

**Homebrew not found**: Restart Terminal or `source ~/.bash_profile`.

**1Password items not found**: Vault name and item titles in `config.conf` have to match exactly.

**VPN monitor keeps restarting Transmission**: That means it's working. The VPN dropped, so the monitor killed Transmission. It'll restart once the tunnel is back. Check PIA's connection.

**Plex not reachable remotely**: Check if the VPN bypass daemon is running: `launchctl list | grep plex-vpn-bypass`. If not, the PF rules aren't in place.

**App not starting on login**: `launchctl list | grep <app>` to check status. Also check `/Users/Shared/` directory permissions.

## Docs

| Topic | Link |
|-------|------|
| What you need before starting | [Prerequisites](docs/prerequisites.md) |
| Configuration options | [Environment Variables](docs/environment-variables.md) |
| Customizing parameters | [Configuration Reference](docs/configuration.md) |
| Building the deployment package | [Prep-AirDrop](docs/setup/prep-airdrop.md) |
| Running system provisioning | [First Boot](docs/setup/first-boot.md) |
| Post-reboot setup | [Operator Setup](docs/operator.md) |
| VPN protection design | [VPN Architecture](docs/vpn-transmission.md) |
| The PIA split tunnel bug | [PIA Bug](docs/pia-split-tunnel-bug.md) |
| How credentials move between machines | [Keychain Management](docs/keychain-credential-management.md) |

## Contributing

Scripts must be idempotent (re-runnable without breaking things). Use `log()`/`show_log()` for output. Use `collect_error()` for blockers, `collect_warning()` for optional stuff, `set_section()` so errors have context. Update docs when you change config. `shellcheck` must pass clean, no exceptions.

## License

MIT; see [LICENSE](license.md)

[![CI Tests](https://github.com/smartwatermelon/mac-server-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/smartwatermelon/mac-server-setup/actions)
