# rclone Setup Script Documentation

This document describes the `rclone-setup.sh` script for Mac Mini M2 server Dropbox synchronization.

## Overview

The `rclone-setup.sh` script automates Dropbox synchronization on macOS with:

- rclone configuration installation from OAuth tokens created during `prep-airdrop.sh`
- Periodic Dropbox sync to local filesystem with configurable intervals
- LaunchAgent auto-start configuration for automatic sync on operator login
- Administrator setup with operator execution model

## Usage

**Script Path**: `./app-setup/rclone-setup.sh`

**Command Line Options**:

- `--force`: Skip all confirmation prompts
- `--skip-sync`: Skip initial synchronization test
- `--sync-interval MINUTES`: Override sync interval (default from config)

**Examples**:

```bash
# Interactive setup with initial sync test
./app-setup/rclone-setup.sh

# Unattended setup without initial sync
./app-setup/rclone-setup.sh --force --skip-sync

# Custom sync interval (every 15 minutes)
./app-setup/rclone-setup.sh --sync-interval 15
```

## Configuration

Set these variables in `config/config.conf` before running `prep-airdrop.sh`:

```bash
DROPBOX_SYNC_FOLDER="/Documents/ServerSync"  # Remote Dropbox folder
DROPBOX_LOCAL_PATH="${HOME}/.local/sync/dropbox"  # Local sync directory
DROPBOX_SYNC_INTERVAL="30"  # Sync interval in minutes
```

## Prerequisites

The script requires configuration files created by `prep-airdrop.sh`:

1. **`app-setup/config/rclone.conf`**: OAuth tokens from browser authentication
2. **`app-setup/config/dropbox_sync.conf`**: Sync configuration settings

## Architecture

### Setup Process

1. **Admin setup**: `rclone-setup.sh` runs as administrator
   - Installs rclone configuration and tests connectivity
   - Deploys sync script to operator account
   - Creates LaunchAgent for auto-start

2. **Operator runtime**: Automatic on operator login
   - LaunchAgent starts sync service
   - Files synced to `~/.local/sync/dropbox`

### File Locations

- **Sync script**: `/Users/${OPERATOR_USERNAME}/.local/bin/start-rclone.sh`
- **LaunchAgent**: `~/Library/LaunchAgents/com.${SERVER_NAME_LOWER}.dropbox-sync.plist`
- **Config**: `~/.config/rclone/rclone.conf`

### Log Locations

- **Setup logs**: `~/.local/state/${SERVER_NAME_LOWER}-apps.log`
- **Sync logs**: `~/.local/state/com.${SERVER_NAME_LOWER}.dropbox-sync.log`

## Manual Operations

### Service Management

```bash
# Check sync service status
launchctl list | grep dropbox-sync

# View live sync logs
tail -f ~/.local/state/com.${SERVER_NAME_LOWER}.dropbox-sync.log

# Manual sync test
rclone sync ${RCLONE_REMOTE_NAME}:${DROPBOX_SYNC_FOLDER} ${DROPBOX_LOCAL_PATH}
```

## Troubleshooting

### Common Issues

**OAuth Token Expiration**: Re-run `prep-airdrop.sh` to refresh tokens

**Network Issues**: Check internet connectivity with `ping dropbox.com`

**Permission Issues**: Verify config file permissions (should be 600)

**Sync Failures**: Check sync logs for specific error messages

### Diagnostics

```bash
# Test rclone configuration
rclone config show ${RCLONE_REMOTE_NAME}
rclone lsd ${RCLONE_REMOTE_NAME}: --max-depth 1

# Check LaunchAgent status
launchctl list com.${SERVER_NAME_LOWER}.dropbox-sync
```

The service integrates with the server's configuration system and follows the administrator-setup, operator-execution model used throughout the project.
