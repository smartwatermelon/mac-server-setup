# Environment Variables Reference

**Complete guide to customizing Mac Mini server setup via environment variables**

## Overview

The Mac Mini server setup system supports extensive customization through environment variables. These can be set in your shell environment, added to `config/config.conf`, or passed directly to scripts.

## Primary Configuration Variables

### Server Identity
**Location**: `config/config.conf` (required)

```bash
# Primary server identifier (affects hostname, volume names, etc.)
SERVER_NAME="MACMINI"

# Day-to-day user account name
OPERATOR_USERNAME="operator"

# Custom hostname override (optional)
HOSTNAME_OVERRIDE=""

# Operator account full name (auto-generated if not set)
OPERATOR_FULLNAME="${SERVER_NAME} Operator"
```

### 1Password Integration
**Location**: `config/config.conf` (required)

```bash
# 1Password vault containing server credentials
ONEPASSWORD_VAULT="personal"

# 1Password item names (customizable)
ONEPASSWORD_OPERATOR_ITEM="operator"
ONEPASSWORD_TIMEMACHINE_ITEM="TimeMachine"
ONEPASSWORD_PLEX_NAS_ITEM="Plex NAS"
ONEPASSWORD_APPLEID_ITEM="Apple"
ONEPASSWORD_OPENSUBTITLES_ITEM="Opensubtitles"
```

### NAS Configuration
**Location**: `config/config.conf` or app-setup scripts

```bash
# NAS connection details
NAS_HOSTNAME="nas.local"
NAS_SHARE_NAME="Media"
NAS_USERNAME="plex"
```

## Advanced Configuration Variables

### Dropbox Synchronization
**Location**: Shell environment or `config/config.conf`

```bash
# Dropbox sync configuration (for rclone setup)
DROPBOX_SYNC_FOLDER="path/to/sync/folder"
DROPBOX_LOCAL_PATH="/Users/operator/Dropbox"
```

**Usage**: When set, prep-airdrop.sh automatically configures Dropbox sync during package preparation.

### FileBot Licensing
**Location**: Shell environment

```bash
# Path to FileBot license file for inclusion in deployment package
FILEBOT_LICENSE_FILE="/path/to/FileBot_License_XXXXXXXXX.psm"
```

**Usage**: If set, prep-airdrop.sh copies the license file to the deployment package for automatic installation.

### Terminal Configuration
**Location**: `config/config.conf`

```bash
# Enable iTerm2 preference export
USE_ITERM2="true"

# Terminal profile file to include (from config/ directory)
TERMINAL_PROFILE_FILE="Orangebrew.terminal"
```

**Usage**: Controls terminal application setup during deployment.

## Runtime Control Variables

### Script Behavior Control
**Location**: Set by scripts during execution

```bash
# Skip confirmation prompts in first-boot.sh
FORCE="true"

# Control software update installation
SKIP_UPDATE="true"     # Recommended - updates unreliable during setup
SKIP_HOMEBREW="false"  # Skip Homebrew installation
SKIP_PACKAGES="false"  # Skip package installation

# Full Disk Access rerun control
RERUN_AFTER_FDA="false"

# Service restart flags
NEED_SYSTEMUI_RESTART="false"
NEED_CONTROLCENTER_RESTART="false"
```

### Administrator Password
**Location**: Runtime collection

```bash
# Administrator password for system modifications
ADMINISTRATOR_PASSWORD=""  # Collected interactively, cleared after use
```

**Security**: Always collected interactively and cleared from memory after use.

## Derived Variables

### Computed Names
**Auto-generated based on primary configuration**

```bash
# Final hostname (with override support)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"

# Lowercase version for file paths
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Operator account display name
OPERATOR_FULLNAME="${SERVER_NAME} Operator"

# Server name in lowercase
SERVER_NAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
```

### File Paths
**Auto-generated directory and file locations**

```bash
# Deployment package output
OUTPUT_PATH="${HOME}/${SERVER_NAME_LOWER}-setup"

# Operator home directory
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"

# Setup and configuration directories
SETUP_DIR="$(pwd)"  # Deployment package root
CONFIG_DIR="${SETUP_DIR}/config"
LOG_DIR="${HOME}/.local/state"

# Application-specific paths
PLEX_MEDIA_MOUNT="${OPERATOR_HOME}/.local/mnt/${NAS_SHARE_NAME}"
LAUNCH_AGENTS_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
```

## Security Variables

### Hardware Fingerprinting
**Location**: Auto-generated during prep-airdrop.sh

```bash
# Development machine hardware fingerprint
DEV_FINGERPRINT="$(system_profiler SPHardwareDataType | grep 'Hardware UUID' | awk '{print $3}')"

# External keychain password (uses hardware UUID)
KEYCHAIN_PASSWORD="${DEV_FINGERPRINT}"
EXTERNAL_KEYCHAIN="mac-server-setup"
```

### Keychain Service Identifiers
**Location**: Auto-generated in keychain manifest

```bash
# Service identifiers for credential retrieval
KEYCHAIN_OPERATOR_SERVICE="operator-${SERVER_NAME_LOWER}"
KEYCHAIN_PLEX_NAS_SERVICE="plex-nas-${SERVER_NAME_LOWER}"
KEYCHAIN_TIMEMACHINE_SERVICE="timemachine-${SERVER_NAME_LOWER}"
KEYCHAIN_WIFI_SERVICE="wifi-${SERVER_NAME_LOWER}"
KEYCHAIN_OPENSUBTITLES_SERVICE="opensubtitles-${SERVER_NAME_LOWER}"
```

## Application-Specific Variables

### Plex Configuration
**Location**: plex-setup.sh runtime

```bash
# Plex server configuration
PLEX_SERVER_NAME="${PLEX_SERVER_NAME_OVERRIDE:-${HOSTNAME}}"
PLEX_PREFS="com.plexapp.plexmediaserver"
LAUNCH_AGENT="com.${HOSTNAME_LOWER}.plexmediaserver"

# Plex directory locations
PLEX_OLD_CONFIG="${HOME}/plex-migration/Plex Media Server"
PLEX_NEW_CONFIG="/Users/Shared/PlexMediaServer"
```

### Transmission Configuration
**Location**: transmission-setup.sh

```bash
# RPC web interface password (optional override)
RPC_PASSWORD="${RPC_PASSWORD:-auto-generated}"
```

## Error Collection Variables

### Error Tracking System
**Location**: All setup scripts

```bash
# Error and warning collection arrays
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()

# Current section context for error reporting
CURRENT_SCRIPT_SECTION=""
```

## Setting Environment Variables

### In config.conf
```bash
# Edit config/config.conf
SERVER_NAME="MYSERVER"
OPERATOR_USERNAME="admin"
USE_ITERM2="true"
```

### In Shell Environment
```bash
# Set before running scripts
export FILEBOT_LICENSE_FILE="/path/to/license.psm"
export DROPBOX_SYNC_FOLDER="Documents/MyProject"
./prep-airdrop.sh
```

### Command Line Override
```bash
# Some variables can be overridden via flags
./plex-setup.sh --server-name "CustomName"
./first-boot.sh --force  # Sets FORCE=true
```

## Variable Validation

### Required Variables
These must be set in `config/config.conf`:
- `SERVER_NAME`
- `OPERATOR_USERNAME`
- `ONEPASSWORD_VAULT`
- All `ONEPASSWORD_*_ITEM` variables

### Optional Variables
These have sensible defaults if not set:
- `HOSTNAME_OVERRIDE` (defaults to `SERVER_NAME`)
- Terminal and application-specific variables
- Dropbox and FileBot configuration

### Auto-Generated Variables
These are computed automatically:
- All `*_LOWER` variables
- All path variables (`*_DIR`, `*_PATH`)
- Hardware fingerprint variables
- Keychain service identifiers

## Troubleshooting

### Common Issues

**Variable Not Taking Effect**:
- Check `config/config.conf` syntax (no spaces around `=`)
- Verify variable is exported in shell environment
- Some variables only work in specific scripts

**Path Variables Incorrect**:
- Ensure `SERVER_NAME` is set correctly
- Check that derived variables are computed properly
- Verify deployment package structure

**1Password Variables**:
- Confirm vault name matches exactly (case-sensitive)
- Verify all required 1Password items exist
- Check `op whoami` authentication status

### Debug Variable Values
```bash
# Check current variable values
echo "SERVER_NAME: ${SERVER_NAME}"
echo "HOSTNAME_LOWER: ${HOSTNAME_LOWER}"
echo "OUTPUT_PATH: ${OUTPUT_PATH}"

# Verify 1Password configuration
echo "Vault: ${ONEPASSWORD_VAULT}"
op item list --vault "${ONEPASSWORD_VAULT}"
```

## Security Considerations

### Sensitive Variables
- `ADMINISTRATOR_PASSWORD`: Never logged, cleared after use
- `*_PASSWORD`: Masked in all log output
- Hardware fingerprints: Used for security validation
- Keychain passwords: Generated from hardware UUID

### Variable Scope
- Configuration variables: Global across all scripts
- Runtime variables: Local to specific script execution
- Derived variables: Computed fresh each time
- Security variables: Auto-generated and protected

This environment variable system provides extensive customization while maintaining security and ease of use.