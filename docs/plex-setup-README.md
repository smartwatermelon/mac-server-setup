# Plex Setup Script Documentation

This document describes the operation, configuration, and troubleshooting of the `plex-setup.sh` script for Mac Mini M2 server setup.

## Overview

The `plex-setup.sh` script automates the deployment of native Plex Media Server on macOS with:

- Native Plex Media Server installation via official macOS installer
- SMB mount to NAS for media storage via autofs
- Shared configuration directory accessible to both admin and operator users
- LaunchAgent configuration for automatic startup with operator login
- Configuration migration from existing Plex servers
- Integration with the server's configuration system

## Script Location and Usage

**Script Path**: `./app-setup/plex-setup.sh`

**Basic Usage**:

```bash
# Run from the server setup directory
./app-setup/plex-setup.sh [OPTIONS]
```

**Command Line Options**:

- `--force`: Skip all confirmation prompts (unattended installation)
- **Default behavior**: Interactive prompts with sensible defaults (Y/n for proceed, y/N for destructive actions)
- `--skip-migration`: Skip Plex configuration migration
- `--skip-mount`: Skip SMB mount setup
- `--server-name NAME`: Set Plex server name (default: hostname)
- `--migrate-from HOST`: Source hostname for Plex migration (e.g., old-server.local)

**Examples**:

```bash
# Full interactive setup with migration
./app-setup/plex-setup.sh

# Unattended fresh installation
./app-setup/plex-setup.sh --force --skip-migration

# Setup without NAS mounting (mount manually later)
./app-setup/plex-setup.sh --skip-mount

# Setup with custom server name
./app-setup/plex-setup.sh --server-name "MyPlexServer"

# Setup with automated migration from existing server
./app-setup/plex-setup.sh --migrate-from old-server.local
```

## Configuration Sources

The script derives its configuration from multiple sources in the following priority order:

### 1. Server Configuration File

**Source**: `config.conf` (in parent directory of script)

**Key Variables Used**:

- `SERVER_NAME`: Primary server identifier
- `OPERATOR_USERNAME`: Non-admin user account name
- `NAS_HOSTNAME`: NAS hostname for SMB connection
- `NAS_USERNAME`: Username for NAS access (deprecated, uses 1Password)
- `NAS_SHARE_NAME`: Name of the media share on NAS
- `HOSTNAME_OVERRIDE`: Custom hostname (optional)
- `ONEPASSWORD_NAS_ITEM`: 1Password item name for NAS credentials (default: plex-nas)

**Derived Variables**:

```bash
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
```

### 2. Derived Script Configuration

**NAS Configuration**:

- `PLEX_MEDIA_MOUNT="/Volumes/${NAS_SHARE_NAME}"` (derived from config.conf)
- SMB credentials retrieved from 1Password

**Native Application Configuration**:

- `PLEX_NEW_CONFIG="/Users/Shared/PlexMediaServer"` (shared directory)
- Application: Native Plex Media Server for macOS
- Server name: `${HOSTNAME} Plex` (customizable via --server-name option)

**Directory Paths**:

- `PLEX_OLD_CONFIG="${HOME}/plex-migration/Plex Media Server"` (migration source)
- `LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-apps.log"`

### 3. Runtime Configuration

**1Password Integration**:

- NAS credentials automatically retrieved from 1Password item
- Fallback prompts if 1Password unavailable
- Secure credential handling with temporary file cleanup

## Expected File Structure

### Plex Migration Files

If migrating from an existing Plex server, place files at:

```plaintext
~/plex-migration/
├── Plex Media Server/          # Complete config directory from old server
│   ├── Plug-in Support/
│   ├── Metadata/
│   ├── Media/
│   ├── Logs/
│   ├── Cache/                  # Will be excluded during migration
│   └── ... (all other subdirectories)
└── com.plexapp.plexmediaserver.plist   # macOS preferences file (optional)
```

**Migration follows official Plex guidelines**: This process is based on Plex's official documentation:

- [Move an Install to Another System](https://support.plex.tv/articles/201370363-move-an-install-to-another-system/)
- [Where is the Plex Media Server Data Directory Located](https://support.plex.tv/articles/202915258-where-is-the-plex-media-server-data-directory-located/)

**How to Obtain These Files** (following [Plex's migration guide](https://support.plex.tv/articles/201370363-move-an-install-to-another-system/)):

1. **Preparation on Source Server**:
   - Disable "Empty trash automatically after every scan" in Plex settings
   - Stop Plex Media Server completely

2. **From macOS Plex Server** (recommended method):

   ```bash
   # On the old server, copy main directory excluding Cache (recommended by Plex)
   rsync -av --exclude='Cache' "~/Library/Application Support/Plex Media Server/" ~/migration-backup/
   
   # Copy the macOS preferences file (optional)
   cp "~/Library/Preferences/com.plexapp.plexmediaserver.plist" ~/migration-backup/
   
   # Transfer to new server at ~/plex-migration/
   ```

3. **Alternative Method** (if rsync unavailable, but slower):

   ```bash
   # Copy complete directory (includes Cache - will be handled during migration)
   cp -R "~/Library/Application Support/Plex Media Server" ~/migration-backup/
   cp "~/Library/Preferences/com.plexapp.plexmediaserver.plist" ~/migration-backup/
   ```

**Important**: The Cache directory can be large and is not needed for migration. The setup script will automatically exclude it during the migration process.

### Generated Directory Structure

After script execution:

```plaintext
/Users/Shared/PlexMediaServer/
└── Plex Media Server/          # Plex configuration (shared access)
    ├── Library/                # Plex application data
    ├── Logs/                   # Plex logs
    └── ... (Plex directory structure)

/Users/${OPERATOR_USERNAME}/Library/LaunchAgents/
└── com.plexapp.plexmediaserver.plist  # Auto-start configuration

~/.local/state/
└── ${HOSTNAME_LOWER}-apps.log         # Script execution log
```

## Operation Flow

### Phase 1: Initialization

1. **Load Configuration**: Sources `config.conf` from parent directory and derives variables
2. **Parse Arguments**: Processes command-line flags
3. **Validate Prerequisites**: Checks 1Password CLI availability
4. **User Confirmation**: Prompts for operation confirmation with sensible defaults (unless `--force`):
   - Setup operations default to **Yes** - press Enter to continue
   - Destructive operations default to **No** - requires explicit confirmation

### Phase 2: SMB Mount Setup

1. **1Password Credential Retrieval**: Securely retrieves NAS credentials from specified vault item
2. **autofs Configuration**: Configures macOS native autofs for automatic mounting
3. **Mount Point Creation**: Creates `/Volumes/${NAS_SHARE_NAME}` with proper permissions
4. **Automatic Mounting**: Sets up autofs rules for on-demand mounting
5. **Service Restart**: Reloads autofs configuration for immediate effect

### Phase 3: Native Application Installation

1. **Application Check**: Verifies if Plex Media Server is already installed
2. **Download**: Downloads latest Plex Media Server for macOS from official source
3. **Installation**: Mounts DMG and copies application to `/Applications/`
4. **Cleanup**: Removes temporary installation files

### Phase 4: Shared Configuration Setup

1. **Shared Directory Creation**: Creates `/Users/Shared/PlexMediaServer` with proper ownership
2. **Permission Configuration**: Sets `admin:staff` ownership with `775` permissions
3. **Staff Group Membership**: Ensures operator user is member of staff group for access
4. **Access Validation**: Verifies both admin and operator can access configuration directory

### Phase 5: Configuration Migration

**Local Migration**:

1. **Migration Check**: Looks for existing config at `~/plex-migration/`
2. **Backup Creation**: Backs up any existing shared config with timestamp
3. **Smart File Copy** (following [Plex best practices](https://support.plex.tv/articles/201370363-move-an-install-to-another-system/)):
   - Preserves all settings, libraries, and metadata
   - Handles permission setup for shared directory
4. **Ownership Setup**: Sets proper file ownership for multi-user access
5. **Post-Migration Guidance**: Provides specific steps for completing the migration

### Phase 6: Auto-Start Configuration

1. **LaunchAgent Creation**: Creates operator-specific LaunchAgent in `~/Library/LaunchAgents/`
2. **Environment Setup**: Configures `PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR` for shared config
3. **Agent Loading**: Loads LaunchAgent for immediate and future startup
4. **Automatic Startup**: Configures Plex to start with operator login

### Phase 7: Application Startup

1. **Initial Launch**: Starts Plex with shared configuration environment
2. **Process Verification**: Confirms Plex Media Server is running
3. **Access URLs**: Provides local and network access information

### Phase 8: Verification

1. **Service Status**: Verifies Plex is running and accessible
2. **Configuration Access**: Confirms shared directory is properly accessible
3. **Final Instructions**: Displays post-setup guidance

## Native Application Configuration

### Shared Configuration Directory

**Location**: `/Users/Shared/PlexMediaServer/`

**Access Control**:

- **Ownership**: `admin:staff`
- **Permissions**: `775` (owner+group read/write, others read)
- **Group Membership**: Operator automatically added to staff group

**Benefits**:

- Administrator installs and configures applications
- Operator can access and modify configurations
- Single source of truth for application settings
- Survives user account changes

### Environment Variables

The LaunchAgent configures:

- `PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR=/Users/Shared/PlexMediaServer`: Directs Plex to use shared config location

### Volume Mounts

- `${PLEX_MEDIA_MOUNT}`: NAS media files via autofs (automatic mounting)

### Process Management

- **Process Owner**: Operator user (runs under operator account)
- **Configuration Access**: Shared directory with multi-user permissions
- **Startup**: Automatic via LaunchAgent when operator logs in

## Auto-Start Configuration

### LaunchAgent Method

**Method**: macOS native LaunchAgent in operator's `~/Library/LaunchAgents/`

**Purpose**: Automatically starts Plex when operator logs in

**Configuration File**: `com.plexapp.plexmediaserver.plist`

**Behavior**:

- Starts when operator logs in
- Restarts if application crashes
- Uses shared configuration directory
- Runs under operator account

**LaunchAgent Features**:

- `RunAtLoad`: Starts immediately when loaded
- `KeepAlive`: Automatically restarts on crash
- Custom environment variables for shared config access
- Standard output/error logging to `/tmp/`

### Automatic NAS Mounting with autofs

**Method**: macOS native autofs subsystem

**Purpose**: Automatically mount NAS share when accessed, survives reboots

**Configuration Files**:

- `/etc/auto_master`: Main autofs configuration
- `/etc/auto_smb`: SMB share definitions

**Setup Process**:

1. **autofs Master Configuration**: Adds `/Volumes auto_smb -nobrowse,nosuid` to `/etc/auto_master`
2. **SMB Configuration**: Creates `/etc/auto_smb` with mount definition:

   ```bash
   ${NAS_SHARE_NAME} -fstype=smbfs,soft ://username:password@hostname/share
   ```

3. **Service Restart**: Reloads autofs configuration with `automount -cv`
4. **Credential Handling**:
   - Uses 1Password credentials for secure storage
   - Handles special characters in passwords properly
   - No plaintext credentials in configuration files

**Behavior**:

- Mount triggered automatically when directory is accessed
- Unmounts automatically after period of inactivity
- Survives system reboots and network reconnections
- No manual mounting required

**Benefits over Manual Mounting**:

- Uses built-in macOS functionality
- More reliable than custom scripts
- Better network handling and reconnection
- Lower system overhead
- Integrated with macOS security model

### Manual Application Management

```bash
# Start Plex manually
launchctl start com.plexapp.plexmediaserver

# Stop Plex (will restart on next login or crash)
launchctl stop com.plexapp.plexmediaserver

# Check LaunchAgent status
launchctl list | grep com.plexapp.plexmediaserver

# View process status
ps aux | grep "Plex Media Server"
```

## Logging

### Script Execution Log

**Location**: `~/.local/state/${HOSTNAME_LOWER}-apps.log`

**Content**: All script operations with timestamps

**Format**:

```plaintext
[YYYY-MM-DD HH:MM:SS] ====== Section Name ======
[YYYY-MM-DD HH:MM:SS] Operation description
[YYYY-MM-DD HH:MM:SS] ✅ Success message
[YYYY-MM-DD HH:MM:SS] ❌ Error message
```

### Application Logs

**LaunchAgent Logs**:

- **Standard Output**: `/tmp/plex-out.log`
- **Standard Error**: `/tmp/plex-error.log`

**Plex Application Logs**:

- **Location**: `/Users/Shared/PlexMediaServer/Plex Media Server/Logs/`
- **Access**: Available to both admin and operator users

**Viewing Logs**:

```bash
# Script execution log
tail -f ~/.local/state/${HOSTNAME_LOWER}-apps.log

# LaunchAgent output
tail -f /tmp/plex-out.log /tmp/plex-error.log

# Plex application logs
ls -la "/Users/Shared/PlexMediaServer/Plex Media Server/Logs/"
```

## Migration Best Practices

### Following Official Plex Guidelines

The migration process implements recommendations from Plex's official documentation:

- **[Move an Install to Another System](https://support.plex.tv/articles/201370363-move-an-install-to-another-system/)**: Complete migration workflow
- **[Where is the Plex Media Server Data Directory Located](https://support.plex.tv/articles/202915258-where-is-the-plex-media-server-data-directory-located/)**: Source directory locations

### Migration Process Details

1. **Cache Directory Handling**:
   - Automatically excluded during migration (Plex recommendation)
   - Cache rebuilds automatically and safely after migration
   - Reduces migration time and storage requirements

2. **Shared Directory Migration**:
   - Copies configuration to shared location for multi-user access
   - Preserves all settings, libraries, and metadata
   - Sets proper permissions for both admin and operator access

3. **Post-Migration Requirements**:
   - Library paths may need updating from old paths to new media mount paths
   - Library scanning required to re-associate media files
   - All libraries should be verified for proper operation

### Expected Migration Timeline

- **Small libraries** (< 1000 items): 5-15 minutes
- **Medium libraries** (1000-10000 items): 15-60 minutes  
- **Large libraries** (> 10000 items): 1+ hours

  *Time depends on library size, metadata complexity, and system performance*

## Troubleshooting

### Common Issues

#### 1. 1Password CLI Not Available

**Symptoms**: Script exits with "1Password CLI not found" message

**Solutions**:

```bash
# Install 1Password CLI
brew install --cask 1password-cli

# Sign in to 1Password
op signin

# Verify access
op whoami
```

#### 2. NAS Mount Failures

**Symptoms**:

- "Mount verification failed" message
- Cannot access media files
- autofs configuration errors

**Solutions**:

```bash
# Check current mounts
mount | grep ${NAS_SHARE_NAME}

# Manual SMB mount test (adjust values per your config.conf)
sudo mkdir -p /Volumes/${NAS_SHARE_NAME}
sudo chown $(whoami):staff /Volumes/${NAS_SHARE_NAME}
mount_smbfs -f 0777 -d 0777 //${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME} /Volumes/${NAS_SHARE_NAME}

# Test NAS connectivity
ping ${NAS_HOSTNAME}

# Check autofs configuration
sudo cat /etc/auto_master | grep auto_smb
sudo cat /etc/auto_smb

# Restart autofs if needed
sudo automount -cv
```

**Common Mount Issues**:

- **1Password authentication failure**:
  - Verify 1Password CLI is signed in: `op whoami`
  - Check NAS credentials in 1Password item
  - Verify item name matches `ONEPASSWORD_NAS_ITEM` config
- **Permission denied after successful mount**:
  - Mount point ownership incorrect
  - Check autofs configuration syntax
- **autofs configuration reset**:
  - macOS system update may have reset `/etc/auto_master`
  - Re-run `plex-setup.sh` to reconfigure autofs

#### 3. Shared Configuration Access Issues

**Symptoms**:

- Permission errors accessing `/Users/Shared/PlexMediaServer/`
- Operator cannot modify Plex configuration

**Solutions**:

```bash
# Check directory permissions
ls -la /Users/Shared/PlexMediaServer/

# Verify group membership
groups
groups ${OPERATOR_USERNAME}

# Fix permissions if needed (run as admin)
sudo chown -R admin:staff /Users/Shared/PlexMediaServer/
sudo chmod -R 775 /Users/Shared/PlexMediaServer/

# Add operator to staff group if missing
sudo dseditgroup -o edit -a ${OPERATOR_USERNAME} -t user staff
```

#### 4. LaunchAgent Issues

**Symptoms**: Plex doesn't start when operator logs in

**Solutions**:

```bash
# Check LaunchAgent status
launchctl list | grep com.plexapp.plexmediaserver

# View LaunchAgent file
cat ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist

# Reload LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist
launchctl load ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist

# Check LaunchAgent logs
tail -f /tmp/plex-out.log /tmp/plex-error.log

# Test environment variable
echo $PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR
```

#### 5. Application Installation Failures

**Symptoms**: Plex Media Server installation fails

**Solutions**:

```bash
# Check if already installed
ls -la "/Applications/Plex Media Server.app"

# Manual download and installation
curl -L -o ~/Downloads/PlexMediaServer.dmg "https://downloads.plex.tv/plex-media-server-new/1.40.4.8679-424562606/macos/PlexMediaServer-1.40.4.8679-424562606-universal.dmg"

# Mount and install manually
hdiutil attach ~/Downloads/PlexMediaServer.dmg
cp -R "/Volumes/Plex Media Server/Plex Media Server.app" /Applications/
hdiutil detach "/Volumes/Plex Media Server"
```

#### 6. Network Access Issues

**Symptoms**: Cannot access Plex web interface

**Solutions**:

```bash
# Check if Plex is running
ps aux | grep "Plex Media Server"

# Test local access
curl -I http://localhost:32400/web

# Check network binding
netstat -an | grep 32400

# Verify hostname resolution
ping macmini.local
```

### Advanced Troubleshooting

#### Reset Plex Configuration

```bash
# Stop Plex
launchctl stop com.plexapp.plexmediaserver

# Backup current config
sudo mv /Users/Shared/PlexMediaServer "/Users/Shared/PlexMediaServer.backup.$(date +%Y%m%d)"

# Create fresh config directory
sudo mkdir -p /Users/Shared/PlexMediaServer
sudo chown admin:staff /Users/Shared/PlexMediaServer
sudo chmod 775 /Users/Shared/PlexMediaServer

# Re-run setup script
./app-setup/plex-setup.sh --skip-migration
```

#### Clean Complete Reinstall

```bash
# Remove Plex application
sudo rm -rf "/Applications/Plex Media Server.app"

# Remove configuration
sudo rm -rf /Users/Shared/PlexMediaServer

# Remove LaunchAgent
rm -f ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist

# Unmount NAS
sudo umount /Volumes/${NAS_SHARE_NAME}

# Re-run full setup
./app-setup/plex-setup.sh
```

#### Manual LaunchAgent Creation

If the script fails to create the LaunchAgent, you can create it manually:

```bash
# Create LaunchAgent directory
mkdir -p ~/Library/LaunchAgents

# Create plist file
cat > ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.plexapp.plexmediaserver</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Plex Media Server.app/Contents/MacOS/Plex Media Server</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR</key>
        <string>/Users/Shared/PlexMediaServer</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/plex-error.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/plex-out.log</string>
</dict>
</plist>
EOF

# Load the LaunchAgent
launchctl load ~/Library/LaunchAgents/com.plexapp.plexmediaserver.plist
```

## Security Considerations

### File Permissions

- Plex config files accessible to both admin and operator
- Application runs with operator user privileges
- NAS mount accessible to operator user
- Shared configuration uses staff group for controlled access

### Network Security

- Application runs as standard user (not root)
- Standard Plex ports exposed for functionality
- No additional network services required
- Native macOS application security model

### Credential Storage

- NAS credentials stored securely in 1Password
- No plaintext passwords in scripts or logs
- Temporary credential files cleaned up automatically
- 1Password CLI handles secure credential retrieval

## Performance Optimization

### Transcoding

- Hardware transcoding available with Plex Pass on Apple Silicon
- Transcoding occurs in application's temporary directory
- Native application benefits from macOS system optimizations

### Media Access

- NAS connection via autofs for optimal performance
- SMB3 protocol used for better performance and security
- Automatic mounting reduces overhead

### Native Application Benefits

- No containerization overhead
- Direct access to macOS hardware acceleration
- Optimal memory management through macOS
- Better integration with system services

## Integration with Server Setup

### Configuration Inheritance

The script inherits configuration from the main server setup:

- Server naming conventions
- User account structure  
- Logging patterns
- 1Password integration

### Compatibility

- Designed to run after `first-boot.sh` completion
- Requires 1Password CLI setup
- Compatible with macOS security model
- Operator account automatically configured for access

### Multi-User Architecture

The script implements the administrator-centric setup pattern:

- **Administrator**: Installs and configures applications
- **Operator**: Consumes pre-configured applications with shared access
- **Shared Resources**: Configuration directories accessible to both users
- **Security**: Controlled access via macOS group membership

### Future Applications

The script pattern can be adapted for other native macOS applications:

- Similar shared configuration approach
- Consistent logging and error handling
- Standard LaunchAgent mechanisms
- 1Password integration for secure credential management
