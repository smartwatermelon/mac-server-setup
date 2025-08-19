# Mac Mini M2 Server Setup

Automated setup scripts for configuring an Apple Silicon Mac Mini as a home server with native macOS applications.

## Project Overview

This project provides a complete automation framework for setting up an Apple Silicon Mac Mini server that functions as:

- **Native application host** (Plex Media Server, web services, system utilities)
- **Central home server** with minimal maintenance requirements
- **Stable, secure, and recoverable system**

## Recent Improvements (v3.0 - Major Overhaul)

### Per-User SMB Mounting with Enhanced Reliability (2025-08-18)

- **Per-user LaunchAgent approach**: Replaced system-level LaunchDaemon with user-specific mounting
  - Each user gets private mount in `~/.local/mnt/DSMedia`
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

- **1Password Credential Integration**: Automated credential retrieval with secure handling
- **Smart Fallbacks**: Interactive prompts when credentials unavailable  
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
  - Required 1Password vault items (see [AirDrop Prep Instructions](docs/airdrop-prep.md))

### Setup Process

1. **Prepare setup package** on your development Mac:

   ```bash
   ./scripts/airdrop-prep.sh
   ```

2. **Transfer to Mac Mini** via AirDrop (entire setup folder)

   > You can use [airdrop-cli](https://github.com/vldmrkl/airdrop-cli) (requires Xcode) to AirDrop files from the command line!
   > Install: (`brew install --HEAD vldmrkl/formulae/airdrop-cli`)

3. **Run initial setup** on Mac Mini:

   ```bash
   cd ~/Downloads/MACMINI-setup # default name
   ./scripts/first-boot.sh
   ```

4. **Complete operator setup** after reboot (see [Operator Setup](docs/operator.md))

## Documentation

- [AirDrop Prep Instructions](docs/setup/airdrop-prep.md) - Preparing the setup package
- [First Boot Instructions](docs/setup/first-boot.md) - Running the initial setup
- [Operator Setup](docs/operator.md) - Post-reboot configuration
- [Configuration Reference](docs/configuration.md) - Customizing setup parameters

## File Structure

```plaintext
.
├── README.md                   # This file
├── scripts/                    # All executable scripts
│   ├── airdrop-prep.sh        # Setup package preparation
│   ├── first-boot.sh          # Main setup script
│   ├── mount-nas-media.sh     # SMB mount script
│   └── dock-cleanup.command   # Operator dock cleanup
├── config/                     # Configuration files
│   ├── config.conf.template   # Configuration template
│   ├── formulae.txt           # Homebrew formulae list
│   └── casks.txt              # Homebrew casks list
├── app-setup/                  # Application setup scripts
│   └── *.sh                   # Individual app installers
└── docs/                       # Documentation
    ├── setup/                 # Setup documentation
    │   ├── airdrop-prep.md
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
- **TouchID sudo access** for local administration
- **Separate operator account** for day-to-day use
- **Automatic login** configured for operator account
- **Firewall configuration** with SSH allowlist
- **Auto-restart** on power failure

## Troubleshooting

### Common Issues

**SSH access denied**: Verify SSH keys were copied correctly and SSH service is enabled.

**TouchID not working**: Ensure `/etc/pam.d/sudo_local` exists and contains proper configuration. **Note:** TouchID cannot coexist with automatic login, so the operator account cannot use TouchID.

**Homebrew not found**: Source shell environment or restart Terminal session.

**1Password items not found**: Verify vault name and item titles match configuration.

**Application not starting**: Check LaunchAgent status with `launchctl list | grep <app>`. Verify shared configuration directory permissions.

### Logs

Setup logs are stored in `~/.local/state/MACMINI-setup.log` with automatic rotation. (Default name)

## Contributing

When modifying scripts:

1. Maintain idempotency - scripts should handle re-runs gracefully
2. Add comprehensive logging via the `log()` and `show_log()` functions
3. Use `check_success()` for error handling
4. Update documentation for any configuration changes

## License

1. MIT; see [LICENSE](license.md)
