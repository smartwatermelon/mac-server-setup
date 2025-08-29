# Keychain-Based Credential Management System

## Overview

The Mac Server Setup framework uses macOS Keychain Services for secure credential storage and transfer. The system replaces plaintext credential files with encrypted keychain storage, transferring credentials from development machine to target server through external keychain files.

## Architecture

### Four-Stage Credential Flow

1. **Development Machine (prep-airdrop.sh)** - Retrieves credentials from 1Password and creates external keychain file
2. **Target Server (first-boot.sh)** - Imports credentials from external keychain to admin and operator keychains  
3. **Application Setup (app-setup/*.sh)** - Retrieves credentials from local keychain for configuration
4. **Runtime Services** - Services and applications retrieve credentials from operator keychain (e.g. mount-nas-media.sh)

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

Two-phase process:

1. **Admin Import** - Transfers credentials from external keychain to admin's keychain
2. **Operator Replication** - Copies credentials to operator's keychain for application access

### Application Usage (app-setup/*.sh)

Uses `get_keychain_credential()` function to retrieve credentials securely, with immediate memory cleanup after use.

### Runtime Services

Services running under operator context retrieve credentials directly from operator keychain for ongoing operations like SMB mounting.

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

Retrieves NAS credentials from keychain for SMB mounting, URL-encodes passwords, and clears credentials from memory immediately after use.

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

- Automatic credential distribution to both admin and operator accounts
- Simple single-function credential retrieval interface
- Error resilience with graceful degradation

### Development

- Consistent credential handling across all scripts
- Integration with Keychain Access.app for debugging

## Troubleshooting

Common diagnostic approaches:

- Verify keychain file existence and permissions
- Test credential retrieval manually with `security` commands
- Check keychain unlock status and access permissions
- Use Keychain Access.app for GUI credential inspection

The system provides comprehensive logging and error collection to identify credential-related issues during setup.
