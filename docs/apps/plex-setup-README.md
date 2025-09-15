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
- `--custom-port PORT`: Set custom port for fresh installations (prevents conflicts)
- `--password PASSWORD`: Provide administrator password for keychain operations

**Examples**:

```bash
# Full interactive setup with migration
./app-setup/plex-setup.sh

# Unattended fresh installation
./app-setup/plex-setup.sh --force --skip-migration

# Automated setup via orchestrator (uses --force)
./run-app-setup.sh

# Setup with custom server name
./app-setup/plex-setup.sh --server-name "MyPlexServer"

# Setup with automated migration
./app-setup/plex-setup.sh --migrate-from old-server.local

# Force mode with custom port to prevent conflicts
./app-setup/plex-setup.sh --force --custom-port 32401
```

## Configuration

The script uses variables from `config.conf`:

```bash
SERVER_NAME="MEDIA"              # Primary server identifier
OPERATOR_USERNAME="operator"     # Non-admin user account
NAS_HOSTNAME="nas.local"         # NAS hostname for SMB
NAS_SHARE_NAME="Media"           # Media share name
ONEPASSWORD_PLEX_NAS_ITEM="Plex NAS"  # 1Password item for NAS credentials
```

## Prerequisites

- Setup completed via first-boot.sh (includes credential import via keychain)
- NAS credentials will be embedded into mount scripts during setup (see [Credential Management](../keychain-credential-management.md))
- For migration: Plex config files in `~/plex-migration/Plex Media Server/`

## Architecture

### Setup Process

1. **Admin setup**: `plex-setup.sh` runs as administrator
   - Installs Plex Media Server application
   - Embeds NAS credentials directly into SMB mount scripts
   - Creates shared configuration directory (`/Users/Shared/PlexMediaServer`)
   - Migrates existing Plex configuration if requested
   - Deploys LaunchAgent and mount scripts to operator account

2. **Operator runtime**: Automatic on operator login
   - LaunchAgent starts Plex with shared configuration
   - SMB mount uses embedded credentials for media access
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

### SSH Security for Migration

**SSH Host Key Verification**: For automated migration workflows, the script uses `StrictHostKeyChecking=no` to prevent blocking on unknown host keys during server-to-server transfers. This is intentional for migration scenarios where:

- Target server may not have established SSH relationships with source servers
- Migration typically occurs between trusted servers on the same network
- Automation workflows need to proceed without manual intervention for host key acceptance

**Security Context**: This setting is used specifically for:

- Migration connection testing: `ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes`
- Automated file transfers during configuration migration
- One-time setup operations between known server pairs

**Note**: This does not affect ongoing SSH security for regular server operations, which continue to use standard SSH host key verification.

### Post-Migration: Home Screen Setup

**⚠️ Important**: After migrating from an existing Plex server, you may need to re-pin your media sources to the home screen.

**What happens during migration**:

- Server configuration and libraries migrate successfully
- Server gets a new name to prevent conflicts with the source server
- Your Plex account recognizes this as a "different" server
- Previously pinned sources become unavailable and disappear from the home screen

**To restore your home screen**:

1. Access your new Plex server via web interface
2. Click "More" in the sidebar navigation
3. Find your migrated libraries (they're still there, just not pinned)
4. Click the pin icon next to each library you want on your home screen
5. Your customized home screen will be restored

This is a one-time setup step that ensures proper server identity while both old and new servers may be running simultaneously during migration.

## Port Conflict Prevention

### Critical Network Port Issue

**⚠️ IMPORTANT**: If you have an existing Plex server running on your network using the default port 32400, installing a new Plex server without migration can cause serious network conflicts.

**The Problem:**

1. **Existing Plex server** uses port 32400 (default)
2. **New Plex installation** also tries to use port 32400 (default)
3. **UPnP/Auto-port mapping** conflicts occur at the router level
4. **Result**: External access to your existing Plex server may be blocked

**Scenarios:**

**✅ SAFE - Migration Mode:**

```bash
# When migrating, ports are automatically managed
./app-setup/plex-setup.sh --migrate-from old-server.local

# Result: Source keeps 32400, target gets 32401 automatically
# No conflicts, both servers accessible
```

**⚠️ RISKY - Fresh Installation:**

```bash
# Without migration, both servers try to use port 32400
./app-setup/plex-setup.sh --skip-migration

# Result: Network port conflicts likely
# May block access to existing Plex server
```

**Migration Benefits:**

- **Automatic port detection**: Script detects source server port via SSH
- **Smart port assignment**: Target gets source port + 1 (e.g., 32400 → 32401)  
- **Router guidance**: Detailed instructions for updating port forwarding
- **Zero conflicts**: Both servers can run simultaneously during transition

## Automation Mode (--force)

When `plex-setup.sh` is run with the `--force` flag (including when called via `run-app-setup.sh`), it operates in automation mode with specific behavior:

### Automatic Decision Making

**✅ Auto-Confirmed (Default "y")**:

- Initial setup confirmation: "Set up Plex Media Server?" → **YES**

**❌ Auto-Declined (Default "n")**:

- Migration prompt: "Do you want to migrate from an existing Plex server?" → **NO**
- Custom port prompt: "Do you want to use a custom port instead of 32400?" → **NO**
- Configuration migration: "Apply migrated Plex configuration?" → **NO**

### Port Conflict Behavior

**Important**: In `--force` mode, Plex setup **always uses port 32400** unless explicitly overridden:

```bash
# Default automation behavior - uses port 32400
./run-app-setup.sh
./app-setup/plex-setup.sh --force

# Result: May conflict with existing Plex servers on network
```

**Enhanced Logging**: When `--force` mode skips custom port selection, the script provides detailed guidance:

```text
⚠️  Using default port 32400 in automation mode
⚠️  If port conflicts occur with existing Plex servers:
   • Rerun with: --custom-port 32401 (or other available port)
   • Check for other Plex servers: dns-sd -B _plexmediasvr._tcp
   • Or use run-app-setup.sh --only plex-setup.sh for interactive setup
```

### Resolving Port Conflicts in Automation

**Option 1: Command-line override**:

```bash
./app-setup/plex-setup.sh --force --custom-port 32401
```

**Option 2: Interactive mode for single app**:

```bash
# Run only Plex setup interactively
./run-app-setup.sh --only plex-setup.sh
```

**Option 3: Detect existing servers**:

```bash
# Check for Plex servers on network before automation
dns-sd -B _plexmediasvr._tcp
# If servers found, use --custom-port
```

### Still Interactive Elements

Even in `--force` mode, these elements remain interactive:

- **Administrator password**: Required for keychain access and sudo operations
- **Server discovery**: When migration is manually specified via `--migrate-from`
- **Plex application launch**: GUI application startup requires user session

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

## Post-Setup Configuration

**⚠️ Important**: After successful Plex setup, you should review and configure your Plex server settings to match your preferences. The setup script automates the basic installation and media access, but many personalization settings require manual configuration.

### Required Manual Configuration

Access your Plex server at `http://your-server.local:32400` and review these settings:

#### **Server Settings** → **General**

- **Server name**: Verify the automatically configured name
- **Language and region**: Set your preferred language and country
- **Remote access**: Configure if you need external access to your server

#### **Server Settings** → **Library**

- **Add media libraries**: Point to your mounted media directories (`~/.local/mnt/Media/...`)
- **Library naming**: Customize library names (Movies, TV Shows, Music, etc.)
- **Scanner settings**: Configure metadata agents and scanner options
- **Artwork and metadata**: Set preferred metadata and artwork sources

#### **Server Settings** → **Network**

- **Remote access**: Enable/disable and configure port forwarding if needed
- **LAN networks**: Add your local network ranges for better security
- **Advanced networking**: Configure if you have complex network requirements

#### **Server Settings** → **Transcoder**

- **Transcoder quality**: Set hardware acceleration preferences (Apple Silicon supports hardware transcoding)
- **Background transcoding**: Configure optimization schedules
- **Bandwidth limits**: Set streaming quality limits if needed

#### **Server Settings** → **Scheduled Tasks**

- **Library maintenance**: Configure automatic library updates
- **Media optimization**: Set up background video optimization
- **Backup schedules**: Configure automatic database backups

### User-Specific Preferences

#### **Account Settings**

- **Privacy settings**: Configure data sharing and analytics preferences
- **Sharing settings**: Set up user access and sharing permissions
- **Online media sources**: Configure or disable online content integration

#### **Playback Settings**

- **Quality settings**: Default streaming quality for different connection types
- **Subtitle settings**: Default subtitle preferences and fonts
- **Audio settings**: Default audio track preferences

### Optional Advanced Configuration

#### **Webhooks and Notifications**

- **Plex webhook**: Configure external service integrations
- **Mobile notifications**: Set up push notifications for mobile apps

#### **DLNA and External Players**

- **DLNA server**: Enable if you have DLNA devices on your network
- **External player support**: Configure for specialized media players

#### **Media Scanner Settings**

- **File detection**: Configure how often libraries are scanned for new content
- **Metadata refresh**: Set automatic metadata update intervals

### Integration with Media Pipeline

If you're using the complete media pipeline (Transmission → FileBot → Plex), verify:

1. **Media library paths** point to the final processed media locations
2. **FileBot output directories** match Plex library scan paths
3. **Transmission completion scripts** are properly moving files to Plex-monitored directories

### Testing Your Configuration

After configuration:

1. **Add test content** to verify library scanning works
2. **Test playback** on different devices to verify transcoding
3. **Check mobile access** if remote access is enabled
4. **Verify media pipeline** by downloading test content through the full workflow

The script integrates with the server's configuration system and follows the administrator-setup, operator-execution model used throughout the project.
