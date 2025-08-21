# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Tip:** Don't say "Perfect!" It isn't perfect. It's merely going as well as can be expected, right now, until it breaks again.

## ⚠️ DEVELOPMENT ENVIRONMENT WARNING ⚠️

**This is a DEVELOPMENT machine, NOT the target Mac Mini server!**

- DO NOT run setup scripts (first-boot.sh, app-setup/*.sh) on this machine
- DO NOT attempt to test system status directly on this machine
- Scripts are prepared here using `airdrop-prep.sh` then transferred to the target server
- Only run linting, validation, and preparation commands on this development machine
- Actual deployment happens on the Mac Mini server after AirDrop transfer

## Project Overview

This is a Mac Mini M2 server setup automation framework that configures Apple Silicon Mac Minis as home servers with native macOS applications. The project follows a two-phase setup approach: base system configuration followed by application deployment.

**IMPORTANT: Always check plan.md first when starting work on this project** - it contains the current development status, active issues, and next priorities. What follows is the general project description and instructions.

## Recent Progress (2025-08-18)

**MAJOR MILESTONE ACHIEVED**: Native Plex installation with per-user SMB mounting confirmed working in production. Operator login automatically triggers SMB mount with media content appearing within seconds.

Major improvements completed:

### ✅ Eliminated unreliable autofs implementation

- Completely removed complex autofs configuration
- Replaced with simple, reliable direct SMB mounting
- Follows proper 4-step mount sequence: mkdir, chown, mount, verify
- Eliminates dangerous `/Volumes` root mounting issues

### ✅ Implemented per-user SMB mounting

- Replaced system-level LaunchDaemon with per-user LaunchAgents
- Each user gets private mount in `~/.local/mnt/DSMedia`
- Eliminates SIP restrictions and permission issues completely
- Same SMB credentials work for both admin and operator users
- Production verified: automatic mounting on operator login

### ✅ Restored missing migration functionality

- Added SSH-based remote migration with rsync/scp fallback
- Restored migration prompt and Plex server discovery
- Added migration size estimation and progress reporting
- Comprehensive remote configuration transfer capability

### ✅ Security and UX improvements

- Added xattr quarantine removal for Plex application
- Pre-configured firewall permissions for Plex
- Automatic network volume access permission grant via tccutil
- Masked passwords in log output for security
- Enhanced LaunchAgent error handling

### ✅ Per-User SMB Mounting (2025-08-18)

- **Per-user LaunchAgent approach**: Replaced system-level LaunchDaemon with user-specific mounting
- **Private user mounts**: Each user gets mount in `~/.local/mnt/DSMedia`
- **Login-triggered mounting**: Mounts activate automatically when users log in
- **No permission issues**: Eliminates SIP restrictions and root permission complications
- **Same SMB credentials**: Both admin and operator use same NAS credentials
- **Production verified**: Confirmed working on operator login with SMB content appearing automatically

## Key Commands

### Setup Process

```bash
# Prepare setup package (run on development Mac)
./scripts/airdrop-prep.sh

# Initial server setup (run on Mac Mini after AirDrop - REQUIRES GUI SESSION)
./scripts/first-boot.sh [--force] [--skip-update] [--skip-homebrew] [--skip-packages]

# Individual application setup (run after base setup)
./app-setup/plex-setup.sh [--force]

# Remote Desktop setup (standalone or integrated into first-boot - REQUIRES GUI SESSION)
./scripts/setup-remote-desktop.sh [--force]
```

**IMPORTANT**: `first-boot.sh` and `setup-remote-desktop.sh` must be run from the Mac's local desktop session, not via SSH. These scripts require GUI access for System Settings automation, AppleScript dialogs, and user account configuration.

### Development Commands

```bash
# Lint shell scripts
shellcheck *.sh app-setup/*.sh

# Test configuration validation
op whoami  # Verify 1Password connectivity
op vault get "${ONEPASSWORD_VAULT}"  # Test vault access
```

### Maintenance Commands

```bash
# TouchID sudo is configured during airdrop-prep.sh

# Operator first-login setup (runs automatically via LaunchAgent)
~/.local/bin/operator-first-login.sh
```

## Architecture

### Two-Phase Setup Design

1. **Base System Setup** (`airdrop-prep.sh` + `first-boot.sh`)
   - System hardening and configuration
   - User account management (admin + operator)
   - SSH access and security setup
   - Homebrew and package installation

2. **Application Setup** (`app-setup/*.sh`)
   - Native macOS application installation and configuration
   - Service-specific configuration
   - Network and storage setup
   - SMB mount configuration for media access

### Configuration System

- **Central config**: `config.conf` contains all customizable parameters
- **1Password integration**: All credentials stored securely in 1Password
- **Derived variables**: Hostnames, paths, and names computed from base configuration
- **Environment-specific**: Support for multiple server configurations

### Security Model

- **SSH key-based authentication** with password auth disabled
- **Operator account isolation** with limited sudo access
- **TouchID sudo** for local administration (admin account only)
- **Credential isolation** via 1Password with temporary file cleanup
- **Firewall configuration** with SSH and limactl pre-approval

## Key Files and Structure

### Core Setup Scripts

- `scripts/airdrop-prep.sh` - Prepares setup package on development Mac
- `scripts/first-boot.sh` - Main setup script for Mac Mini
- `config/config.conf` - Central configuration file (copy from `config/config.conf.template`)
- `scripts/mount-nas-media.sh` - Persistent SMB mount script (installed to `$HOME/.local/bin/` per user)
- `scripts/operator-first-login.sh` - Operator account customization (dock cleanup, etc.) run automatically on first login

### Operator Setup

- `operator-first-login.sh` - Function-based operator customization framework
  - Deployed to `$OPERATOR_HOME/.local/bin/` by `first-boot.sh`
  - Config copied to `$OPERATOR_HOME/.config/operator/config.conf`
  - LaunchAgent created for automatic execution on first operator login
  - Includes dock cleanup with retry logic and extensible task system

### Application Setup

- `app-setup/plex-setup.sh` - Native Plex Media Server installation with persistent SMB mounting

### Remote Desktop Setup

- `scripts/setup-remote-desktop.sh` - User-guided Remote Desktop configuration for macOS 15.6+
  - **Requires GUI session**: Must be run from Mac's local desktop, not via SSH
  - Works with Apple's security model instead of against it
  - Uses AppleScript dialogs for step-by-step System Settings guidance
  - Proper execution order: Screen Sharing first, then Remote Management
  - Fully functional as standalone script or integrated into first-boot.sh
  - Clean slate approach: disables existing services for reliable setup
  - Supports both VNC (Screen Sharing) and Apple Remote Desktop (Remote Management)
  - Validates session type with `launchctl managername` before proceeding

### Package Management

- `config/formulae.txt` - Homebrew command-line tools
- `config/casks.txt` - Homebrew GUI applications

### Configuration Management

Configuration follows a hierarchical approach:

1. Base configuration in `config.conf`
2. Derived variables computed by scripts
3. 1Password items for sensitive data
4. Environment-specific overrides supported

Key configuration variables:

- `SERVER_NAME` - Primary server identifier (affects hostname, volumes, etc.)
- `OPERATOR_USERNAME` - Day-to-day user account name
- `ONEPASSWORD_VAULT` - 1Password vault containing credentials
- `MONITORING_EMAIL` - Email for system notifications

## Development Practices

### Script Conventions

- All scripts use `set -euo pipefail` for error handling
- Idempotent design - scripts can be run multiple times safely
- Comprehensive logging via `log()` and `show_log()` functions
- Error checking with `check_success()` function
- **Confirmation prompts** with sensible defaults:
  - Setup operations: (Y/n) - default Yes, press Enter to continue
  - Destructive operations: (y/N) - default No, requires explicit confirmation
  - Use `--force` flag to skip all prompts for unattended operation
- **Contextual sudo prompts**: All `sudo` commands include descriptive prompts
  - Format: `sudo -p "[Category] Enter password to <action>: "`
  - Categories: TouchID setup, System setup, SSH setup, Account setup, etc.
- **Proper user context**: Use `sudo -iu` for commands requiring full user environment (Homebrew, `defaults`, etc)

### Administrator-Centric Setup Design

- **All configuration and setup performed in administrator context**: `first-boot.sh` and `app-setup/*.sh` scripts run as administrator
- **Operator account is consumption-focused**: Operator logs in to a fully configured system
- **Minimize operator-side setup**: After reboot to operator context, system should be ready to use
- **Shared access model**: Administrator configures services that operator will use, with proper permissions for both users
- **Automatic operator customization**: `operator-first-login.sh` runs automatically on first login via LaunchAgent for dock setup and other operator-specific customizations
- **Service ownership**: Services may run under operator account but are configured by administrator with appropriate access rights

### 1Password Integration

- Use `op` CLI for all credential operations on the developer machine
- Do not attempt to use `op` on the server
- Items auto-created if missing (operator account)
- Temporary credential files with 600 permissions
- Automatic cleanup of sensitive temporary files

### File Permissions

Setup scripts handle file permissions automatically:

- Setup scripts: 755
- Credential files: 600
- SSH keys: 600 (private), 644 (public)
- **Shared application configs**: 775 with admin:staff ownership (enables admin setup + operator access)

## Common Development Tasks

### Git

1. All development work takes place in branches, never on `main`, and **you will never merge to main, nor will you make edits on main.**
2. When starting, check which git branch you are on. If you are not already on a branch named e.g. `claude-20250818`, ask if you should create one, and then switch to it.
3. You should feel free to `git add` and `git commit` changes as you make them. A commit hook will validate changes to shell scripts and Markdown files before allowing the commit to proceed; you should work in a methodical manner to address changes suggested by the tools called from the commit hook, then re-add the affected files and attempt the commit again.

### Open local files in BBEdit

1. Execute from the project directory on the development machine:

```bash
find . \( -name '*.conf' -or -name '*.template' -or -name '*.txt' -or -name '*.sh' -or -name '*.md' \) -exec bbedit {} \;
```

### Adding New Applications

1. Create new script in `app-setup/` following existing patterns
2. Use native macOS installation where possible
3. Follow naming convention: `${SERVER_NAME_LOWER}-${app}`
4. Configure logging to `~/.local/state/${hostname}-apps.log`
5. **Use shared configuration directories**: Store app configs in `/Users/Shared/` with proper permissions for multi-user access

### Modifying Configuration

1. Update `config/config.conf.template` for new parameters
    - Post a reminder to make corresponding changes in `config/config.conf`
2. Update `docs/configuration.md` with documentation
3. Ensure backward compatibility with existing setups
4. Test with multiple server name configurations

### Testing Changes

1. Use `shellcheck` for static analysis
2. Test with `--force` flag to skip prompts
3. Verify idempotency by running scripts multiple times

## Troubleshooting

### Common Issues

- **"GUI session required" error**: Many setup scripts require desktop access
  - Run `first-boot.sh` and `setup-remote-desktop.sh` from local Mac desktop session
  - Check session: `launchctl managername` should return `Aqua` (not `Background`)
  - Cannot run via SSH - requires direct access to Mac's screen and System Settings
- **SSH access denied**: Check SSH key transfer and service enablement
- **1Password authentication**: Verify `op signin` and vault access
- **Homebrew not found**: Source shell environment or restart Terminal
- **Permission errors**: Check file permissions on setup directory

### Setup Script Execution Order Issues

- **`brew: command not found` errors**: Commands trying to use Homebrew before installation
  - Fixed: Proper ordering of package installation before usage
- **Permission errors**: Using `sudo -u` instead of `sudo -iu` for operator commands
  - Fixed: Changed to `sudo -iu` for proper login shell environment with correct HOME, PWD, and PATH

### Log Locations

- Setup logs: `~/.local/state/${server-name}-setup.log`
- Application logs: `~/.local/state/${server-name}-apps.log`
- Mount logs: `~/.local/state/${server-name}-mount.log`
- Operator login logs: `~/.local/state/${server-name}-operator-login.log`
- LaunchAgent logs: `~/.local/state/com.${server-name}.mount-nas-media.log`
- Operator LaunchAgent logs: `~/.local/state/com.${server-name}.operator-first-login.log`
- System logs: Standard macOS Console.app locations

### Per-User SMB Mount Troubleshooting

- **Check mount status**: `mount | grep ${NAS_SHARE_NAME}` (should show mount at `~/.local/mnt/${NAS_SHARE_NAME}`)
- **View mount logs**: `tail -f ~/.local/state/${server-name}-mount.log`
- **Check LaunchAgent status**: `launchctl list | grep mount-nas-media`
- **Manual mount test**: `~/.local/bin/mount-nas-media.sh`
- **Restart mount service**: `launchctl unload` then `launchctl load ~/Library/LaunchAgents/com.${server-name}.mount-nas-media.plist`
- **Access mounted share**: `ls ~/.local/mnt/${NAS_SHARE_NAME}` (per-user access)

### Remote Desktop Troubleshooting

- **"GUI session required" error**: Script attempted to run via SSH or non-desktop session
  - Must run from Mac's local desktop session (Terminal.app or similar)
  - Check session type: `launchctl managername` should return `Aqua` for GUI sessions
  - `Background` indicates SSH or non-GUI session - run locally instead
- **Connection refused**: Verify both Screen Sharing and Remote Management are enabled in System Settings > General > Sharing
- **Service order issues**: Run `./scripts/setup-remote-desktop.sh` to ensure proper setup sequence (Screen Sharing first, then Remote Management)
- **Apple Remote Desktop not working**: Ensure Remote Management (not just Screen Sharing) is enabled
- **VNC connection works but ARD doesn't**: Remote Management required for full Apple Remote Desktop functionality
- **Manual setup**: If automated setup fails, manually enable in System Settings > General > Sharing
- **Permission issues**: Check that user accounts have appropriate access configured in sharing settings
- **Script execution**: Run with `--force` flag to skip confirmation prompts: `./scripts/setup-remote-desktop.sh --force`

### Operator First-Login Troubleshooting

- **Check script deployment**: Verify `~/.local/bin/operator-first-login.sh` exists and is executable
- **Check config deployment**: Verify `~/.config/operator/config.conf` exists
- **Check LaunchAgent**: `launchctl list | grep operator-first-login`
- **View operator logs**: `tail -f ~/.local/state/${server-name}-operator-login.log`
- **Manual execution**: Run `~/.local/bin/operator-first-login.sh` manually for testing
- **LaunchAgent logs**: Check `~/.local/state/com.${server-name}.operator-first-login.log`
- **Restart LaunchAgent**: `launchctl unload ~/Library/LaunchAgents/com.${server-name}.operator-first-login.plist && launchctl load ~/Library/LaunchAgents/com.${server-name}.operator-first-login.plist`

### Configuration Validation

Before running setup, verify:

- 1Password CLI authenticated (`op whoami`)
- Required 1Password items exist in specified vault
- SSH keys present at expected locations
- Network name conflicts resolved

### Native Application Integration

The setup configures native macOS applications for optimal server operation:

- **Per-user SMB mounting**: Automatic NAS mounting via per-user LaunchAgents to `~/.local/mnt/` for reliable media access
- **LaunchAgent configuration**: Applications configured to start automatically with operator login
- **Shared configuration access**: Apps use `/Users/Shared/` directories with proper multi-user permissions
- **Environment variables**: LaunchAgents configured with custom paths for shared access
- **Network access**: Applications accessible via `hostname.local:port` addresses
- **macOS integration**: Native system integration with notifications and menu bar access
- **Login-time mounting**: SMB shares automatically mount when each user logs in via LaunchAgent

## When done processing this file, say "I have fully read CLAUDE.md"

- Be comfortable automatically git add / git commit your code changes.
- ALWAYS read plan.md alongside CLAUDE.md.
- Prefer fixing or modifying script to address shellcheck concerns rather than overriding shellcheck warnings.
