# Mac Mini M2 Server Setup - Implementation Notes

## Project Overview

This document provides technical implementation details for the Mac Mini M2 server setup project. The approach emphasizes simplicity, reliability, and one-time execution over complex system management.

## Core Design Philosophy

The implementation follows a **"run once and done"** philosophy rather than building a complex management system:

- **Single Execution**: Scripts designed to set up the server once successfully
- **Minimal Complexity**: Straightforward bash scripting without over-engineering
- **1Password Integration**: Leverages existing credential management infrastructure
- **Error Handling**: Robust but simple error detection and recovery
- **Clear Separation**: Base OS setup separate from containerized applications

## Key Technical Decisions

### 1. Scripting Approach

**Simple Bash with Essential Features**:

- `set -e` for immediate error exit
- Comprehensive logging with timestamps
- Idempotent operations (safe to re-run)
- Interactive prompts with `--force` mode override
- macOS-specific commands (`scutil`, `defaults`, `systemsetup`)

This approach prioritizes reliability and maintainability over sophisticated automation frameworks.

### 2. Credential Management Strategy

**1Password Integration** eliminates password generation complexity:

**Preparation Phase** (`airdrop-prep.sh`):

- Checks for existing "TILSIT operator" credentials in 1Password
- Creates credentials if missing using secure generation
- Retrieves password via `op read` command
- Transfers only the password value (not generation logic)

**Setup Phase** (`first-boot.sh`):

- Reads password from transferred file
- Creates operator account using exact password
- Verifies authentication works immediately
- Stores reference to 1Password location
- Removes password file after successful setup

**Benefits**:

- Eliminates password generation/verification mismatches
- Centralized credential management
- Secure storage with enterprise-grade encryption
- Easy maintenance and retrieval
- No complex password verification logic needed

### 3. User Account Structure

**Two-User Model**:

- **Administrator Account**: Your Apple ID-linked account for system management
- **Operator Account**: Limited-privilege account with 1Password-managed credentials

The operator account password is never stored locally - only a reference to its 1Password location is maintained.

### 4. Xcode Command Line Tools Installation

**Silent Installation Approach**:

```bash
sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
softwareupdate -i "$(softwareupdate -l | grep Label | tail -n 1 | cut -d ':' -f 2 | xargs)"
```

This method:

- Avoids complex AppleScript automation
- Requires no Accessibility permissions
- Always installs latest available version
- Works completely unattended
- Eliminates user interaction dialogs

### 5. Homebrew Installation

**Official Installation Script**:

- Uses `NONINTERACTIVE=1` flag for automation
- Follows Homebrew's exact post-installation recommendations
- Dynamic path detection for Intel vs Apple Silicon
- Proper shell configuration for `.zprofile` and compatibility profiles
- Verification using `brew help` to ensure functionality

### 6. Network Configuration

**Intelligent WiFi Handling**:

- Checks current network before attempting configuration
- Skips setup if already connected to target network
- Handles preferred networks list to avoid duplicates
- Graceful handling of connection timing issues
- Secure credential cleanup after setup

### 7. SSH Configuration

**Secure Remote Access**:

- Public key authentication only
- Separate keys for admin and operator accounts
- Full Disk Access handling with clear user guidance
- Firewall configuration for SSH access
- No password-based authentication

### 8. Container Strategy

**Docker-Based Application Isolation**:

- Individual containers for each application
- Shared Docker network (`tilsit-network`)
- Host volume mounting for persistent data
- Automatic restart policies
- Consistent environment configuration

## Technical Implementation Details

### Boot Process Flow

1. **macOS Setup**: Manual completion of setup wizard
2. **File Transfer**: AirDrop of prepared setup files
3. **First-Boot Script**: Complete system configuration and package installation
4. **Application Setup**: Individual containerized application configuration

Each phase builds on a stable foundation from the previous phase.

### Error Handling Strategy

**Graceful Degradation**:

- Check current state before making changes
- Skip operations that are already complete
- Clear logging for troubleshooting
- Non-fatal warnings for optional features
- `--force` mode for automation scenarios

### Package Management

**Homebrew Integration**:

- Text file-based package lists (`formulae.txt`, `casks.txt`)
- Installation state checking to avoid duplicates
- Proper environment variable configuration
- Architecture-aware setup (Intel vs Apple Silicon)
- Clean separation of formulae and casks

### Security Implementation

**Defense in Depth**:

- Firewall enabled with specific application exceptions
- SSH key-based authentication only
- Limited-privilege operator account
- **1Password for all credential storage**
- **No plaintext passwords on server**
- Automatic security updates (configurable)
- Screen saver password requirements

## 1Password Integration Details

### Workflow Architecture

1. **Development Machine**:
   - Manages credentials in 1Password vault
   - Uses `op read` to retrieve passwords
   - Transfers only password values, not generation logic

2. **Mac Mini Setup**:
   - Receives password from transfer file
   - Creates accounts using exact password
   - Verifies authentication immediately
   - Stores only reference to 1Password location

3. **Ongoing Management**:
   - Password always available via `op read "op://personal/TILSIT operator/password"`
   - Updates managed through 1Password interface
   - No local password storage or generation

### Security Benefits

- **Enterprise-grade encryption** for credential storage
- **Centralized management** across all devices
- **Audit trail** of password access and changes
- **No local credential storage** on server
- **Reliable verification** - exact password matching guaranteed

## Customization Points

### Media Storage Configuration

```bash
PLEX_MEDIA_DIR="/Volumes/MediaDrive"  # Configurable in plex-setup.sh
```

### Monitoring Configuration

```bash
EMAIL_ALERTS="your.email@example.com"  # Configurable in monitoring setup
```

### Application-Specific Settings

Each application setup script contains configurable variables for directories, credentials, and timezone settings.

## Limitations and Considerations

### Current Limitations

1. **Manual macOS Setup**: Initial setup wizard requires user interaction
2. **One-time Use**: Scripts not designed for ongoing system management
3. **Basic Monitoring**: Simple health checks rather than comprehensive monitoring
4. **Static Configuration**: Container settings defined at setup time

### Future Considerations

1. **Backup Strategy**: Implement regular configuration backups
2. **Update Management**: Establish update policies for containers and packages
3. **Monitoring Enhancement**: Consider more sophisticated monitoring if needed
4. **Documentation**: Maintain setup procedures as macOS evolves

## Maintenance Approach

### Regular Tasks

- **macOS Security Updates**: Monthly review and application
- **Package Updates**: Quarterly `brew update && brew upgrade`
- **Container Updates**: As-needed basis for security or feature updates
- **Configuration Backups**: Quarterly backup of settings and data

### Credential Management

- **Password Rotation**: Update in 1Password as needed
- **SSH Key Management**: Periodic review and rotation
- **Access Auditing**: Regular review of account access

## Common Issues and Solutions

### Setup Issues

1. **SSH Permission Problems**: Handled by Full Disk Access guidance
2. **WiFi Configuration**: Graceful handling of connection timing
3. **Package Installation**: Xcode CLT installation automated
4. **Password Verification**: Eliminated through 1Password integration

### Runtime Issues

1. **Container Problems**: Standard Docker troubleshooting applies
2. **Network Issues**: Standard macOS network diagnostics
3. **Performance**: Monitor system resources via health checks

## Conclusion

This implementation provides a practical, maintainable approach to Mac Mini server setup that emphasizes:

- **Simplicity over complexity** - straightforward scripts rather than elaborate frameworks
- **Reliability over features** - proven approaches rather than experimental techniques  
- **Security through integration** - leveraging 1Password rather than custom credential management
- **One-time execution** - setup scripts rather than ongoing management systems

The **1Password integration** represents the key architectural decision that eliminates the most common source of setup failures while providing enterprise-grade credential security. The approach acknowledges that this is a home server setup that needs to work reliably without requiring ongoing script maintenance or complex orchestration systems.

The careful attention to idempotency and error handling ensures the setup process is robust, while the clear separation of concerns makes the system understandable and maintainable by someone with basic bash and Docker knowledge.
