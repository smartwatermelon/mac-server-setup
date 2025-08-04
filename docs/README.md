# Mac Mini M2 Server Setup (TILSIT)

Automated setup scripts for configuring a Mac Mini M2 as a home server with containerized applications.

## Project Overview

This project provides a complete automation framework for setting up a Mac Mini M2 server that functions as:
- **Containerized application host** (Plex, torrent tools, web services)
- **Central home server** with minimal maintenance requirements
- **Stable, secure, and recoverable system**

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

- Mac Mini M2 with fresh macOS installation
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

3. **Run initial setup** on Mac Mini:
   ```bash
   cd ~/Downloads/tilsit-setup/scripts
   ./first-boot.sh
   ```

4. **Complete operator setup** after reboot (see [Operator Setup](docs/operator-setup.md))

## Documentation

- [AirDrop Prep Instructions](docs/airdrop-prep.md) - Preparing the setup package
- [First Boot Instructions](docs/first-boot.md) - Running the initial setup
- [Operator Setup](docs/operator-setup.md) - Post-reboot configuration
- [Configuration Reference](docs/configuration.md) - Customizing setup parameters

## File Structure

```
.
├── README.md                    # This file
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
    ├── operator-setup.md
    └── configuration.md
```

## Configuration

The system uses `config.conf` for customization:

```bash
SERVER_NAME="TILSIT"
OPERATOR_USERNAME="operator"
ONEPASSWORD_VAULT="personal"
ONEPASSWORD_OPERATOR_ITEM="TILSIT operator"
ONEPASSWORD_TIMEMACHINE_ITEM="PECORINO DS-413 - TimeMachine"
ONEPASSWORD_APPLEID_ITEM="Apple"
MONITORING_EMAIL="your-email@example.com"
```

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

**TouchID not working**: Ensure `/etc/pam.d/sudo_local` exists and contains proper configuration.

**Homebrew not found**: Source shell environment or restart Terminal session.

**1Password items not found**: Verify vault name and item titles match configuration.

### Logs

Setup logs are stored in `~/.local/state/tilsit-setup.log` with automatic rotation.

## Contributing

When modifying scripts:
1. Maintain idempotency - scripts should handle re-runs gracefully
2. Add comprehensive logging via the `log()` and `show_log()` functions
3. Use `check_success()` for error handling
4. Update documentation for any configuration changes

## License

This project is provided as-is for personal and educational use.