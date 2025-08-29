# Configuration Reference

The Mac Mini server setup is controlled by the `config.conf` file, which allows customization of server identity, credentials, and behavior without modifying the setup scripts.

## Configuration File Format

The configuration uses simple shell variable syntax:

```bash
# config.conf - Configuration file for Mac Mini server setup

# Server identity
SERVER_NAME="MACMINI"
OPERATOR_USERNAME="operator"

# 1Password configuration
ONEPASSWORD_VAULT="personal"
ONEPASSWORD_OPERATOR_ITEM="operator"
ONEPASSWORD_TIMEMACHINE_ITEM="TimeMachine"
ONEPASSWORD_PLEX_NAS_ITEM="Plex NAS"
ONEPASSWORD_APPLEID_ITEM="Apple"

# Monitoring
MONITORING_EMAIL="your-email@example.com"

# Optional overrides (leave empty to use defaults)
HOSTNAME_OVERRIDE=""
```

## Core Configuration Parameters

### Server Identity

**SERVER_NAME**: Primary identifier for the server

- **Default**: "MACMINI"
- **Used for**: Hostname, volume name, network identification
- **Format**: Uppercase, no spaces (DNS-safe)
- **Example**: `SERVER_NAME="HOMESERVER"`

**OPERATOR_USERNAME**: Name for the day-to-day user account

- **Default**: "operator"
- **Used for**: User account creation, SSH access, automatic login
- **Format**: Lowercase, no spaces (Unix username format)
- **Example**: `OPERATOR_USERNAME="server"`

### 1Password Integration

The system uses 1Password for initial credential retrieval during setup preparation, then transfers credentials securely via macOS Keychain Services. See [Keychain-Based Credential Management](keychain-credential-management.md) for complete details.

**ONEPASSWORD_VAULT**: 1Password vault containing server credentials

- **Default**: "personal"
- **Example**: `ONEPASSWORD_VAULT="Infrastructure"`

**ONEPASSWORD_OPERATOR_ITEM**: Login item for operator account password

- **Default**: "operator"
- **Requirements**: Login item with username and password
- **Auto-creation**: Script creates item if it doesn't exist

**ONEPASSWORD_TIMEMACHINE_ITEM**: Login item for Time Machine backup credentials

- **Default**: "TimeMachine"
- **Requirements**: Login item with username, password, and URL field

**ONEPASSWORD_PLEX_NAS_ITEM**: Login item for Plex media NAS credentials

- **Default**: "Plex NAS"
- **Requirements**: Login item with username, password, and URL field (optional)

**ONEPASSWORD_APPLEID_ITEM**: Login item for Apple ID credentials

- **Default**: "Apple"
- **Requirements**: Login item with Apple ID email and password

### Optional Overrides

**HOSTNAME_OVERRIDE**: Custom hostname different from SERVER_NAME

- **Default**: Empty (uses SERVER_NAME)
- **When to use**: When you want a different network hostname
- **Example**: `HOSTNAME_OVERRIDE="media-server"`

**MONITORING_EMAIL**: Email address for system notifications

- **Default**: "<andrew.rich@gmail.com>" (should be customized)
- **Usage**: Future monitoring system integration
- **Example**: `MONITORING_EMAIL="admin@yourdomain.com"`

## Derived Variables

The setup scripts automatically calculate additional variables based on your configuration:

### Computed Names

**HOSTNAME**: Final hostname for the system

```bash
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
```

**HOSTNAME_LOWER**: Lowercase version for file paths and system naming

```bash
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
```

**OPERATOR_FULLNAME**: Display name for operator account

```bash
OPERATOR_FULLNAME="${SERVER_NAME} Operator"
```

### File Paths

**Setup directory structure** based on SERVER_NAME:

- Setup package: `~/macmini-setup` (for SERVER_NAME="MACMINI")
- Scripts directory: `~/macmini-scripts`
- Log files: `~/.local/state/macmini-setup.log`

## Customization Examples

### Multiple Server Setup

For managing multiple Mac Mini servers with different roles:

```bash
# Media server configuration
SERVER_NAME="MEDIASERVER"
OPERATOR_USERNAME="media"
ONEPASSWORD_OPERATOR_ITEM="MediaServer Operator"
ONEPASSWORD_TIMEMACHINE_ITEM="MediaServer TimeMachine"
```

```bash
# Development server configuration
SERVER_NAME="DEVSERVER"
OPERATOR_USERNAME="dev"
ONEPASSWORD_OPERATOR_ITEM="DevServer Operator"
ONEPASSWORD_TIMEMACHINE_ITEM="DevServer TimeMachine"
```

### Corporate Environment

For business use with organizational 1Password:

```bash
SERVER_NAME="INFRASTRUCTURE"
OPERATOR_USERNAME="sysadmin"
ONEPASSWORD_VAULT="IT Infrastructure"
ONEPASSWORD_OPERATOR_ITEM="Mac Mini Infrastructure Operator"
ONEPASSWORD_TIMEMACHINE_ITEM="Enterprise Backup - Mac Mini"
ONEPASSWORD_APPLEID_ITEM="Apple ID Corporate"
MONITORING_EMAIL="it-alerts@company.com"
```

### Home Lab Integration

For integration with existing home lab infrastructure:

```bash
SERVER_NAME="HOMELAB"
HOSTNAME_OVERRIDE="mac-mini-01"
MONITORING_EMAIL="homelab@yourdomain.local"
```

## Validation and Testing

### Configuration Validation

Before running `airdrop-prep.sh`, verify your 1Password items exist:

```bash
# Test 1Password connectivity
op whoami

# Verify vault exists
op vault get "${ONEPASSWORD_VAULT}"

# Check operator item (auto-created if missing)
op item get "${ONEPASSWORD_OPERATOR_ITEM}" --vault "${ONEPASSWORD_VAULT}" || echo "Will be created"

# Verify Time Machine item exists
op item get "${ONEPASSWORD_TIMEMACHINE_ITEM}" --vault "${ONEPASSWORD_VAULT}"

# Verify Plex NAS item exists (optional - will fall back to plex_nas.conf file)
op item get "${ONEPASSWORD_PLEX_NAS_ITEM}" --vault "${ONEPASSWORD_VAULT}" || echo "Will use plex_nas.conf file"

# Verify Apple ID item exists
op item get "${ONEPASSWORD_APPLEID_ITEM}" --vault "${ONEPASSWORD_VAULT}"
```

### Network Name Testing

Test that your chosen server name resolves properly on your network:

```bash
# After setup, test resolution
ping "${HOSTNAME_LOWER}.local"

# Test SSH connectivity
ssh operator@"${HOSTNAME_LOWER}.local"
```

## Security Considerations

### Credential Storage

The system uses a secure four-stage credential management process via macOS Keychain Services. See [Keychain-Based Credential Management](keychain-credential-management.md) for complete implementation details.

**SSH Keys**: Public keys only are transferred; private keys remain on your development Mac.

### Access Control

**Operator Account Isolation**: The operator account has limited sudo access appropriate for server management.

**SSH Key Sharing**: Admin and operator accounts share SSH keys by default for convenience, but this can be customized.

**Apple ID Sharing**: One-time sharing links expire after first use for security.

## Troubleshooting Configuration Issues

### 1Password Authentication

**Item not found errors**:

```bash
# List all items to verify naming
op item list --vault "${ONEPASSWORD_VAULT}"

# Check exact item title
op item get "exact-item-name" --vault "${ONEPASSWORD_VAULT}"
```

**Vault access denied**:

```bash
# Verify vault permissions
op vault list
op vault get "${ONEPASSWORD_VAULT}"
```

### Network Configuration

**Hostname conflicts**: If your chosen SERVER_NAME conflicts with existing network devices, use HOSTNAME_OVERRIDE:

```bash
HOSTNAME_OVERRIDE="unique-hostname"
```

**DNS resolution issues**: Some networks require manual DNS configuration for .local domains.

### File Permission Issues

**Setup directory access**: Ensure setup files have correct permissions:

```bash
# Fix common permission issues
chmod 755 ~/macmini-setup/scripts/*.sh
chmod 600 ~/macmini-setup/config/mac-server-setup-db
chmod 600 ~/macmini-setup/config/wifi_network.conf
```

## Advanced Configuration

### Custom Package Lists

Modify the package installation by editing these files before running `airdrop-prep.sh`:

**config/formulae.txt**: Command-line tools installed via Homebrew
**config/casks.txt**: GUI applications installed via Homebrew

Example customization:

```bash
# Add to config/formulae.txt
htop
ncdu
tree

# Add to config/casks.txt
visual-studio-code
firefox
vlc
```

### Environment-Specific Overrides

Create environment-specific configuration files:

```bash
# config-production.conf
SERVER_NAME="PRODSERVER"
ONEPASSWORD_VAULT="Production Infrastructure"
MONITORING_EMAIL="production-alerts@company.com"

# config-staging.conf
SERVER_NAME="STAGINGSERVER"
ONEPASSWORD_VAULT="Staging Infrastructure"
MONITORING_EMAIL="staging-alerts@company.com"
```

Use with airdrop-prep.sh by copying the appropriate config:

```bash
cp config-production.conf config/config.conf
./prep-airdrop.sh
```

### Integration Hooks

The configuration system supports future extension points:

**MONITORING_EMAIL**: Reserved for future monitoring system integration
**Custom variables**: Add your own variables to config.conf for use in custom scripts

## Migration and Backup

### Configuration Backup

**Version control**: Store your config.conf in a private Git repository
**1Password backup**: Export your server-related 1Password items periodically
**SSH key backup**: Ensure SSH keys are backed up separately from the server

### Server Migration

To migrate configuration to a new Mac Mini:

1. **Update SERVER_NAME** in config.conf if needed
2. **Run airdrop-prep.sh** with updated configuration
3. **Transfer setup package** to new Mac Mini
4. **Run first-boot.sh** as normal

The new server will inherit all configurations and credentials from 1Password.

### Disaster Recovery

**Complete rebuild**: With config.conf and 1Password items intact, you can rebuild the entire server from scratch
**Credential rotation**: Update 1Password items to rotate credentials without changing scripts
**Network reconfiguration**: Modify HOSTNAME_OVERRIDE to change network identity without affecting other settings

This configuration system provides flexibility for various deployment scenarios while maintaining security and automation principles.
