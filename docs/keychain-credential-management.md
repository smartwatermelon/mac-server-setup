# Keychain-Based Credential Management System

## Overview

The Mac Server Setup framework uses macOS Keychain Services for secure credential storage and transfer. The system replaces plaintext credential files with encrypted keychain storage, transferring credentials from development machine to target server through external keychain files.

## Architecture

### Three-Stage Credential Flow

1. **Development Machine (prep-airdrop.sh)** - Retrieves credentials from 1Password and creates external keychain file
2. **Target Server (first-boot.sh)** - Imports credentials from external keychain to admin keychain only
3. **Application Setup (app-setup/*.sh)** - Retrieves credentials from admin keychain and embeds them into service scripts with restrictive file permissions for secure runtime access

## Credential Services

### Required Credentials

- **`operator-{SERVER_NAME_LOWER}`**: Operator account password
- **`plex-nas-{SERVER_NAME_LOWER}`**: NAS credentials for media access (format: `username:password`)

### Optional Credentials

- **`timemachine-{SERVER_NAME_LOWER}`**: Time Machine backup credentials (format: `username:password`)
- **`wifi-{SERVER_NAME_LOWER}`**: WiFi password for network setup

## Implementation

### External Keychain Transfer (prep-airdrop.sh)

Creates temporary keychain with random password, stores credentials from 1Password, verifies storage, locks keychain, and copies to output directory with manifest file.

Service identifiers:

- `KEYCHAIN_OPERATOR_SERVICE="operator-${SERVER_NAME_LOWER}"`
- `KEYCHAIN_PLEX_NAS_SERVICE="plex-nas-${SERVER_NAME_LOWER}"`
- `KEYCHAIN_TIMEMACHINE_SERVICE="timemachine-${SERVER_NAME_LOWER}"`
- `KEYCHAIN_WIFI_SERVICE="wifi-${SERVER_NAME_LOWER}"`

### Credential Import (first-boot.sh)

Single-phase admin import process:

1. **Admin Import** - Transfers credentials from external keychain to admin's keychain

**Note**: Operator keychain population has been removed as it's no longer needed. The operator account is created before first login, meaning no login keychain exists yet. SMB credentials are embedded directly into service scripts during application setup, eliminating the need for operator keychain access.

### Application Usage (app-setup/*.sh)

Uses `get_keychain_credential()` function to retrieve credentials securely during setup, then embeds them directly into service scripts with restrictive file permissions (mode 700) for runtime access.

### Runtime Services

Services use embedded credentials that were securely inserted during application setup. This eliminates the need for interactive keychain unlocks in LaunchAgent contexts while maintaining security through restrictive file permissions.

## Credential Formats

- **NAS Credentials**: `username:password` format, parsed with bash parameter expansion
- **Simple Credentials**: Plain password strings for account creation and network auth

## Security Features

- Encrypted keychain storage eliminates plaintext credential files
- Immediate credential verification prevents corrupt transfers
- Memory cleanup after credential use
- Proper file permissions (600) on keychain files and manifests
- Password masking in logs
- External keychain cleanup after import

## Integration Points

### mount-nas-media.sh Template

Uses embedded NAS credentials that were securely inserted during plex-setup.sh execution. Credentials are validated during script startup, URL-encoded for SMB mounting, and protected by restrictive file permissions (mode 700).

### Configuration Files

- **keychain_manifest.conf**: Contains service identifiers and keychain metadata
- **External keychain file**: `mac-server-setup-db` transferred with setup package

## Error Handling

- Graceful handling of missing optional credentials
- Verification of credential storage and retrieval
- Comprehensive error collection and reporting

## Benefits

### Security

- Encrypted storage throughout transfer process
- No plaintext credential files in setup packages
- Proper access controls and memory management

### Operations  

- Automatic credential storage in admin keychain during setup
- Simple single-function credential retrieval interface for setup scripts
- Embedded credentials in service scripts eliminate runtime keychain dependencies
- Error resilience with graceful degradation

### Development

- Consistent credential handling across all scripts
- Integration with Keychain Access.app for debugging

## Troubleshooting

### Admin Keychain Issues

Common diagnostic approaches for setup-time credential issues:

- Verify keychain file existence and permissions
- Test credential retrieval manually with `security` commands
- Check keychain unlock status and access permissions  
- Use Keychain Access.app for GUI credential inspection

### Embedded Credential Issues

For runtime credential problems with service scripts:

- **Script permissions**: Verify service scripts have mode 700 permissions

  ```bash
  ls -la ~/.local/bin/mount-nas-media.sh
  # Should show: -rwx------
  ```

- **Credential validation**: Check for unconfigured placeholders in scripts

  ```bash
  grep "__.*__" ~/.local/bin/mount-nas-media.sh
  # Should return no results if properly configured
  ```

- **Service script logs**: Check service-specific log files

  ```bash
  tail -f ~/.local/state/${server-name}-mount.log
  ```

The system provides comprehensive logging and error collection to identify credential-related issues during setup.
