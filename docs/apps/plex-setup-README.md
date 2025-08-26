# Plex Setup Script Documentation

This document describes the `plex-setup.sh` script for Mac Mini server Plex Media Server setup.

## Overview

The `plex-setup.sh` script automates native Plex Media Server deployment on macOS with:

- Native Plex Media Server installation via official macOS installer
- Direct SMB mounting for NAS media storage access
- Shared configuration directory accessible to both admin and operator users
- LaunchAgent configuration for automatic startup with operator login
- SSH-based remote migration from existing Plex servers with server discovery
- Administrator setup with operator execution model

## Usage

**Script Path**: `./app-setup/plex-setup.sh`

**Command Line Options**:

- `--force`: Skip all confirmation prompts
- `--skip-migration`: Skip Plex configuration migration
- `--skip-mount`: Skip SMB mount setup
- `--server-name NAME`: Set Plex server name (default: hostname)
- `--migrate-from HOST`: Source hostname for Plex migration

**Examples**:

```bash
# Full interactive setup with migration
./app-setup/plex-setup.sh

# Unattended fresh installation
./app-setup/plex-setup.sh --force --skip-migration

# Setup with custom server name
./app-setup/plex-setup.sh --server-name "MyPlexServer"

# Setup with automated migration
./app-setup/plex-setup.sh --migrate-from old-server.local
```

## Configuration

The script uses variables from `config.conf`:

```bash
SERVER_NAME="MEDIA"              # Primary server identifier
OPERATOR_USERNAME="operator"     # Non-admin user account
NAS_HOSTNAME="nas.local"         # NAS hostname for SMB
NAS_SHARE_NAME="Media"           # Media share name
ONEPASSWORD_NAS_ITEM="plex-nas"  # 1Password item for NAS credentials
```

## Prerequisites

- 1Password CLI configured and authenticated
- NAS credentials stored in 1Password
- For migration: Plex config files in `~/plex-migration/Plex Media Server/`

## Architecture

### Setup Process

1. **Admin setup**: `plex-setup.sh` runs as administrator
   - Installs Plex Media Server application
   - Configures SMB mount with NAS credentials
   - Creates shared configuration directory (`/Users/Shared/PlexMediaServer`)
   - Migrates existing Plex configuration if requested
   - Deploys LaunchAgent to operator account

2. **Operator runtime**: Automatic on operator login
   - LaunchAgent starts Plex with shared configuration
   - SMB mount provides media access
   - Plex runs under operator account

### File Locations

- **Application**: `/Applications/Plex Media Server.app`
- **Shared config**: `/Users/Shared/PlexMediaServer/`
- **Mount script**: `~/.local/bin/mount-nas-media.sh`
- **LaunchAgent**: `~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist`
- **Media mount**: `~/.local/mnt/${NAS_SHARE_NAME}`

### Log Locations

- **Setup logs**: `~/.local/state/${HOSTNAME_LOWER}-apps.log`
- **Plex logs**: `/Users/Shared/PlexMediaServer/Plex Media Server/Logs/`
- **LaunchAgent logs**: `/tmp/plex-out.log`, `/tmp/plex-error.log`

## Migration

### Preparing Migration Files

From existing macOS Plex server:

```bash
# Stop Plex and copy config (excluding Cache)
rsync -av --exclude='Cache' "~/Library/Application Support/Plex Media Server/" ~/migration-backup/

# Transfer to new server at ~/plex-migration/
```

The script supports both local migration (files in `~/plex-migration/`) and remote migration via SSH.

## Manual Operations

### Service Management

```bash
# Check Plex status
launchctl list | grep com.plexapp.plexmediaserver
ps aux | grep "Plex Media Server"

# Start/stop Plex
launchctl start com.plexapp.plexmediaserver
launchctl stop com.plexapp.plexmediaserver

# View logs
tail -f ~/.local/state/${HOSTNAME_LOWER}-apps.log
tail -f /tmp/plex-out.log /tmp/plex-error.log

# Check NAS mount
mount | grep ${NAS_SHARE_NAME}
ls ~/.local/mnt/${NAS_SHARE_NAME}
```

### SMB Mount Management

```bash
# Manual mount test
~/.local/bin/mount-nas-media.sh

# Check mount LaunchAgent
launchctl list | grep mount-nas-media

# View mount logs
tail -f ~/.local/state/${HOSTNAME_LOWER}-mount.log
```

## Troubleshooting

### Error Collection and Summary

The Plex setup script includes comprehensive error and warning collection:

- **Real-time display**: Errors and warnings show immediately during setup
- **End-of-run summary**: Consolidated review of all issues when setup completes
- **Context tracking**: Each issue shows which setup section it occurred in

Example summary output:

```bash
====== PLEX SETUP SUMMARY ======
Plex setup completed, but 1 error and 2 warnings occurred:

ERRORS:
  ❌ Installing Plex Media Server: Homebrew installation failed

WARNINGS:
  ⚠️ Setting Up Per-User SMB Mount: Admin SMB mount failed - check credentials
  ⚠️ Configuring Remote Migration: SSH connection to old-server.local failed

Review the full log for details: ~/.local/state/macmini-apps.log
```

### Common Issues

**1Password CLI Issues**:

```bash
# Install and authenticate
brew install --cask 1password-cli
op signin
op whoami
```

**NAS Mount Failures**:

```bash
# Test connectivity and credentials
ping ${NAS_HOSTNAME}
op item get ${ONEPASSWORD_NAS_ITEM}

# Manual SMB mount test
mkdir -p ~/.local/mnt/${NAS_SHARE_NAME}
mount_smbfs //${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME} ~/.local/mnt/${NAS_SHARE_NAME}
```

**Shared Config Access Issues**:

```bash
# Check permissions
ls -la /Users/Shared/PlexMediaServer/
groups ${OPERATOR_USERNAME}

# Fix permissions
sudo chown -R admin:staff /Users/Shared/PlexMediaServer/
sudo chmod -R 775 /Users/Shared/PlexMediaServer/
sudo dseditgroup -o edit -a ${OPERATOR_USERNAME} -t user staff
```

**LaunchAgent Issues**:

```bash
# Reload LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist
launchctl load ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist

# Check LaunchAgent file
cat ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist
```

### Reset and Reinstall

```bash
# Clean reinstall
sudo rm -rf "/Applications/Plex Media Server.app"
sudo rm -rf /Users/Shared/PlexMediaServer
rm -f ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist

# Re-run setup
./app-setup/plex-setup.sh
```

The script integrates with the server's configuration system and follows the administrator-setup, operator-execution model used throughout the project.
