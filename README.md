# Mac Mini M2 Server Setup

Automated setup scripts for configuring an Apple Silicon Mac Mini as a home server with containerized applications.

## Project Overview

This project provides a complete automation framework for setting up an Apple Silicon Mac Mini server that functions as:

- **Containerized application host** (Plex, torrent tools, web services)
- **Central home server** with minimal maintenance requirements
- **Stable, secure, and recoverable system**

## Recent Improvements (v2.0)

### Enhanced Plex Setup with Robust SMB Mounting

- **Reliable SMB Mounting**: Fixed authentication issues and improved mount reliability
  - Username case conversion for SMB compatibility
  - URL encoding for passwords with special characters
  - Proper mount point ownership and permissions
- **macOS Native autofs Integration**: Automatic NAS mounting using built-in macOS functionality
  - Survives reboots and network reconnections
  - More reliable than custom LaunchAgent scripts
  - Uses `/etc/auto_master` and `/etc/auto_smb` configuration
- **Improved Error Handling**: Clear sudo prompts and better debugging information
- **Clean Server Discovery**: Fixed Plex server discovery display for migration setup

### 1Password Credential Integration

- **Automated Credential Retrieval**: NAS credentials automatically retrieved from 1Password
- **Secure Credential Handling**: No plaintext passwords in scripts or logs
- **Smart Fallbacks**: Interactive prompts when 1Password credentials unavailable
- **Intuitive Confirmations**: Sensible defaults for all prompts (Y/n for proceed, y/N for destructive)

## Key Principles

- **Separation of Concerns**: Base OS setup separate from containerized applications
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

   - Containerized application deployment
   - Service configuration
   - Monitoring setup

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
   ./airdrop-prep.sh
   ```

2. **Transfer to Mac Mini** via AirDrop (entire setup folder)

   > You can use [airdrop-cli](https://github.com/vldmrkl/airdrop-cli) (requires Xcode) to AirDrop files from the command line!
   > Install: (`brew install --HEAD vldmrkl/formulae/airdrop-cli`)

3. **Run initial setup** on Mac Mini:

   ```bash
   cd ~/Downloads/MACMINI-setup/scripts # default name
   ./first-boot.sh
   ```

4. **Complete operator setup** after reboot (see [Operator Setup](docs/operator.md))

## Documentation

- [AirDrop Prep Instructions](docs/airdrop-prep.md) - Preparing the setup package
- [First Boot Instructions](docs/first-boot.md) - Running the initial setup
- [Operator Setup](docs/operator.md) - Post-reboot configuration
- [Configuration Reference](docs/configuration.md) - Customizing setup parameters

## File Structure

```plaintext
.
├── README.md                   # This file
├── config.conf                 # Configuration parameters
├── airdrop-prep.sh             # Setup package preparation
├── first-boot.sh               # Main setup script
├── create-touchid-sudo.sh      # TouchID sudo enablement
├── dock-cleanup.command        # Operator dock cleanup
├── formulae.txt                # Homebrew formulae list
├── casks.txt                   # Homebrew casks list
├── app-setup/                  # Application setup scripts
│   └── *.sh                    # Individual app installers
└── docs/                       # Documentation
    ├── airdrop-prep.md
    ├── first-boot.md
    ├── operator.md
    └── configuration.md
```

## Configuration

The system uses `config.conf` for customization:

```bash
SERVER_NAME="YOUR_SERVER_NAME"
OPERATOR_USERNAME="operator"
ONEPASSWORD_VAULT="personal"
ONEPASSWORD_OPERATOR_ITEM="server operator"
ONEPASSWORD_TIMEMACHINE_ITEM="TimeMachine"
ONEPASSWORD_APPLEID_ITEM="Apple"
MONITORING_EMAIL="your-email@example.com"
```

## Docker Support

This project uses **Colima** instead of Docker Desktop for containerized applications:

- **Headless operation** - No GUI required, perfect for server use
- **Lightweight** - Much smaller resource footprint than Docker Desktop
- **Auto-start** - Automatically starts when operator logs in
- **Drop-in replacement** - Compatible with all Docker commands and scripts

Colima is automatically installed and configured during setup. Docker Desktop can still be used if preferred, but Colima is recommended for server deployments.

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

**Docker/Colima not working**: Check if Colima is running with `colima status`. Start manually with `colima start` if needed.

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
