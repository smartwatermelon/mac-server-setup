# Mac Mini Server Setup

Automated setup scripts for configuring an Apple Silicon Mac Mini as a home server with native macOS applications.

## Project Overview

This project provides a complete automation framework for setting up an Apple Silicon Mac Mini server that functions as:

- **Native application host** (Plex Media Server, web services, system utilities)
- **Central home server** with minimal maintenance requirements
- **Stable, secure, and recoverable system**

## Recent Improvements (v3.0 - Major Overhaul)

### Comprehensive Error and Warning Collection (2025-08-26)

- **Real-time + End Summary**: All errors and warnings display immediately during setup, plus consolidated review at completion
  - Preserves existing immediate feedback during fast-scrolling operations
  - Shows organized summary when setup completes and user attention returns
  - Context tracking shows which setup section each issue occurred in
- **Consistent Across All Scripts**: Unified error handling across the entire setup process
  - **prep-airdrop.sh**: Missing files, SSH keys, WiFi detection, credential issues
  - **first-boot.sh**: System setup, package installation, service configuration
  - **plex-setup.sh**: Plex installation, SMB mounting, migration processes
  - **rclone-setup.sh**: Dropbox sync configuration and testing
- **Better Troubleshooting**: Clear distinction between expected warnings vs critical errors
  - Expected warnings (optional components): SSH private keys, WiFi detection
  - Critical errors (setup blockers): Missing credentials, system failures
  - Section context helps pinpoint exactly where issues occurred

### Per-User SMB Mounting with Enhanced Reliability (2025-08-18)

- **Per-user LaunchAgent approach**: Replaced system-level LaunchDaemon with user-specific mounting
  - Each user gets private mount in `~/.local/mnt/MOUNT_POINT`
  - LaunchAgents activate on user login, no root permissions needed
  - Same SMB credentials work for both admin and operator users
  - Eliminates SIP restrictions and permission issues
- **Enhanced Security and UX**: Comprehensive improvements for production use
  - Password masking in logs prevents credential exposure
  - Automatic firewall configuration for Plex Media Server
  - Network volume permissions pre-granted via tccutil
  - Application quarantine removal for seamless operation
- **Restored Migration Features**: Full SSH-based remote migration capability
  - Automatic Plex server discovery on network
  - Remote configuration transfer with rsync/scp fallback
  - Migration size estimation and progress reporting
- **Production-Ready Reliability**: Robust error handling and fallback mechanisms

### Previous Improvements (v2.0)

- **Keychain-Based Credential Management**: Secure credential storage and transfer via macOS Keychain Services (see [Credential Management](docs/keychain-credential-management.md))
- **1Password Integration**: Automated credential retrieval from 1Password during setup preparation
- **Intuitive Confirmations**: Sensible defaults for all prompts

## Key Principles

- **Separation of Concerns**: Base OS setup separate from native application deployment
- **Automation First**: Minimal human intervention throughout lifecycle
- **Idempotency**: Scripts can be run multiple times safely
- **Security**: Hardening and isolation best practices
- **Documentation**: Clear runbooks for all procedures

## Architecture

The setup process consists of two main phases:

1. **Base System Setup** (`airdrop-prep.sh` + `first-boot.sh`)

   - System configuration and hardening
   - User account management
   - SSH access and security
   - Package installation (Homebrew)

2. **Application Setup** (separate scripts in `app-setup/`)

   - Native macOS application installation and configuration
   - Shared configuration directory setup
   - LaunchAgent auto-start configuration

## Quick Start

### Prerequisites

- Apple Silicon Mac Mini with fresh macOS installation
- Development Mac with:
  - 1Password CLI installed and authenticated
  - SSH keys generated (`~/.ssh/id_ed25519.pub`)
  - Required 1Password vault items (see [AirDrop Prep Instructions](docs/setup/prep-airdrop.md))

> **Compatibility Note**: This automation is designed and tested for **macOS 15.x on Apple Silicon**. It may work on earlier macOS versions or Intel-based Macs, but compatibility is not guaranteed and has not been tested.

### Setup Process

1. **Prepare setup package** on your development Mac:

   ```bash
   ./prep-airdrop.sh
   ```

2. **Transfer to Mac Mini** via AirDrop (entire setup folder)

   > You can use [airdrop-cli](https://github.com/vldmrkl/airdrop-cli) (requires Xcode) to AirDrop files from the command line!
   > Install: (`brew install --HEAD vldmrkl/formulae/airdrop-cli`)

3. **Run initial setup** on Mac Mini (**requires local desktop session**):

   ```bash
   cd ~/Downloads/MACMINI-setup # default name
   ./first-boot.sh
   ```

   > **Important**: Must be run from the Mac Mini's local desktop session (not via SSH). The script requires GUI access for System Settings automation, AppleScript dialogs, and user account configuration.

4. **Complete operator setup** after reboot (see [Operator Setup](docs/operator.md))

## Documentation

- [AirDrop Prep Instructions](docs/setup/prep-airdrop.md) - Preparing the setup package
- [First Boot Instructions](docs/setup/first-boot.md) - Running the initial setup
- [Operator Setup](docs/operator.md) - Post-reboot configuration
- [Configuration Reference](docs/configuration.md) - Customizing setup parameters

## File Structure

```plaintext
.
├── README.md                   # This file
├── prep-airdrop.sh             # Setup package preparation (primary entry point)
├── app-setup/                  # Application setup scripts
│   ├── config/                # Application-specific configuration
│   │   ├── plex_nas.conf      # Plex NAS configuration
│   │   ├── rclone.conf        # rclone OAuth configuration
│   │   └── dropbox_sync.conf  # Dropbox sync settings
│   ├── templates/             # Runtime script templates
│   │   ├── mount-nas-media.sh # SMB mount script template
│   │   ├── start-plex-with-mount.sh # Plex startup wrapper template
│   │   └── start-rclone.sh    # rclone sync script template
│   ├── plex-setup.sh          # Plex Media Server setup
│   └── rclone-setup.sh        # Dropbox sync setup
├── scripts/                    # Setup and deployment scripts
│   ├── airdrop/               # AirDrop preparation scripts
│   │   └── rclone-airdrop-prep.sh # Dropbox setup for AirDrop
│   └── server/                # Server setup scripts
│       ├── first-boot.sh      # Main setup script (requires GUI session)
│       ├── setup-remote-desktop.sh # Remote Desktop configuration (requires GUI session)
│       └── operator-first-login.sh # Operator account customization (automatic via LaunchAgent)
├── config/                     # Configuration files
│   ├── config.conf.template   # Configuration template
│   ├── formulae.txt           # Homebrew formulae list
│   └── casks.txt              # Homebrew casks list
└── docs/                       # Documentation
    ├── setup/                 # Setup documentation
    │   ├── prep-airdrop.md
    │   └── first-boot.md
    ├── apps/                  # App-specific docs
    ├── operator.md
    └── configuration.md
```

## Configuration

The system uses `config/config.conf` for customization:

```bash
SERVER_NAME="YOUR_SERVER_NAME"
OPERATOR_USERNAME="operator"
ONEPASSWORD_VAULT="personal"
ONEPASSWORD_OPERATOR_ITEM="server operator"
ONEPASSWORD_TIMEMACHINE_ITEM="TimeMachine"
ONEPASSWORD_APPLEID_ITEM="Apple"
MONITORING_EMAIL="your-email@example.com"
```

## Native Application Architecture

This project uses **native macOS applications** with **direct SMB mounting**:

- **Optimal performance** - Direct access to macOS hardware acceleration and native mount handling
- **Shared configuration** - Multi-user access via `/Users/Shared/` directories
- **LaunchAgent integration** - Applications start automatically with operator login
- **Direct SMB mounting** - Reliable mount process without complex autofs dependencies
- **Administrator-centric setup** - Complete configuration by admin, consumption by operator

Key improvements eliminate previous autofs reliability issues and provide robust, debuggable mounting.

## Security Features

- **SSH key-based authentication** with password fallback disabled
- **TouchID sudo access** configured during setup for local administration
- **Separate operator account** for day-to-day use
- **Automatic login** configured for operator account
- **Firewall configuration** with SSH allowlist
- **Auto-restart** on power failure

## Troubleshooting

### Common Issues

**"GUI session required" error**: Setup scripts require local desktop access, not SSH.

- Run `first-boot.sh` and `setup-remote-desktop.sh` from the Mac Mini's desktop (Terminal.app)
- Check session: `launchctl managername` should return `Aqua` (not `Background`)
- Cannot run via SSH - requires direct access for System Settings and AppleScript dialogs

**SSH access denied**: Verify SSH keys were copied correctly and SSH service is enabled.

**TouchID not working**: TouchID sudo is configured during first-boot setup. **Note:** TouchID cannot coexist with automatic login, so the operator account cannot use TouchID.

**Homebrew not found**: Source shell environment or restart Terminal session.

**1Password items not found**: Verify vault name and item titles match configuration.

**Application not starting**: Check LaunchAgent status with `launchctl list | grep <app>`. Verify shared configuration directory permissions.

### Error Collection and Logs

**Error Collection System**: All setup scripts now provide both immediate error feedback and end-of-run summaries:

```bash
====== SETUP SUMMARY ======
Setup completed, but 1 error and 2 warnings occurred:

ERRORS:
  ❌ Installing Homebrew Packages: Formula installation failed: some-package

WARNINGS:
  ⚠️ Copying SSH Keys: SSH private key not found at ~/.ssh/id_ed25519
  ⚠️ WiFi Network Configuration: Could not detect current WiFi network

Review the full log for details: ~/.local/state/macmini-setup.log
```

**Log Files**: Setup logs are stored in `~/.local/state/MACMINI-setup.log` with automatic rotation. (Default name)

- **prep-airdrop.sh**: Console output during preparation (no separate log file)
- **first-boot.sh**: `~/.local/state/macmini-setup.log`
- **plex-setup.sh**: `~/.local/state/macmini-apps.log`
- **rclone-setup.sh**: `~/.local/state/macmini-apps.log`

## Contributing

When modifying scripts:

1. Maintain idempotency - scripts should handle re-runs gracefully
2. Add comprehensive logging via the `log()` and `show_log()` functions
3. Use error collection system:
   - `collect_error()` for critical failures that may block setup
   - `collect_warning()` for non-critical issues (missing optional components)
   - `set_section()` to provide context for error tracking
   - `check_success()` for automatic error handling
4. Update documentation for any configuration changes

## License

1. MIT; see [LICENSE](license.md)

[![CI Tests](https://github.com/smartwatermelon/mac-server-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/smartwatermelon/mac-server-setup/actions)
