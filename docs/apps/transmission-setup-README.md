# Transmission Setup Documentation

**Script**: `app-setup/transmission-setup.sh`  
**Purpose**: BitTorrent client installation and comprehensive GUI automation  
**Created**: 2025-09-08  
**Status**: Production ready  

## Overview

The `transmission-setup.sh` script provides complete automation for Transmission BitTorrent client setup with ~95% GUI preference coverage and seamless media pipeline integration.

## Key Features

### Complete GUI Automation

- **Verified Preferences**: Uses only confirmed plist keys from actual configuration analysis
- **Download Management**: Configures download paths, seeding limits, and completion handling
- **Network Configuration**: Peer settings, encryption, port mapping, and blocklist automation
- **UI Settings**: Auto-resize, confirmation prompts, and watch folder configuration

### System Integration

- **Magnet Link Handler**: Automatically configures Transmission as default magnet link application
- **Launch Services**: Uses macOS Launch Services for proper URL scheme registration
- **LaunchAgent**: Creates operator login auto-start configuration
- **RPC Web Interface**: Enables remote access at `http://hostname.local:19091`

### Media Pipeline Integration

- **Download Paths**: Configures downloads to media mount location
- **Completion Scripts**: Creates FileBot integration script template
- **Watch Folder**: Integrates with rclone sync directory for automated processing
- **Workflow**: Supports Catch → Transmission → FileBot → Plex pipeline

## Configuration Details

### Automated Preferences

**Download Settings**:

- Download folder: `~/.local/mnt/Media/Media/Torrents/pending-move`
- Constant download location (not "Same as torrent file")
- Incomplete downloads folder: disabled
- Delete original torrent files: enabled

**Network Settings**:

- Fixed peer port: 40944
- Port mapping (UPnP): enabled
- µTP protocol: enabled
- Connection limits: 2048 total peers, 256 per torrent

**Peer Protocol**:

- PEX (Peer Exchange): enabled
- DHT (Distributed Hash Table): enabled
- Local peer discovery: enabled
- Encryption: prefer and require

**Queue Management**:

- Download queue: disabled (unlimited)
- Seed queue: disabled (unlimited)
- Stalled detection: 30 minutes
- Auto-removal after seeding completion

**Seeding Limits**:

- Ratio limit: 2.0 (200%)
- Idle time limit: 30 minutes
- Remove when finished seeding: enabled

**UI Configuration**:

- Auto-resize columns: enabled
- Confirmation prompts: disabled for removal and quit
- Watch folder: `~/.local/sync/dropbox` (rclone sync)

**Blocklist**:

- Enabled with auto-update
- Source: `https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz`

**RPC (Web Interface)**:

- Port: 19091
- Authentication: required
- Username: hostname (lowercase)
- Password: hostname (lowercase, configurable)
- Whitelist: 0.0.0.0, 127.0.0.1

### Manual Configuration Required

**Remaining tasks for operator** (documented in `docs/operator.md`):

1. **System Notifications**: Click "Configure in System Preferences" for download completion notifications
2. **Sleep Prevention**: Enable "Prevent computer from sleeping with active transfers" if desired

## Usage

### Command Line Options

```bash
./transmission-setup.sh [OPTIONS]

Options:
  --force                    Skip all confirmation prompts
  --rpc-password PASSWORD    Override RPC password (default: hostname)
```

### Integration with App Setup

The script integrates with the app setup orchestrator:

```bash
# Run all applications including Transmission
./run-app-setup.sh

# Run only Transmission setup
./run-app-setup.sh --only transmission-setup.sh

# Run with custom RPC password
./transmission-setup.sh --rpc-password "custom_password"
```

### Verification

After setup completion, verify configuration:

```bash
# Check application installation
ls -la /Applications/Transmission.app

# Verify RPC web interface
curl -u hostname:hostname http://hostname.local:19091/transmission/rpc/

# Check LaunchAgent
launchctl list | grep transmission

# Verify magnet link handler
defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers | grep -A3 -B3 magnet
```

## Architecture

### Script Structure

- **Configuration Loading**: Uses central `config/config.conf` file
- **Environment Setup**: Ensures Homebrew availability
- **Installation**: Native Transmission.app via Homebrew cask
- **Preference Configuration**: Comprehensive `defaults write` commands
- **System Integration**: Launch Services and LaunchAgent setup
- **Completion**: Creates FileBot integration script

### File Locations

- **Application**: `/Applications/Transmission.app`
- **Preferences**: `~/Library/Preferences/org.m0k.transmission.plist`
- **Launch Services**: `~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist`
- **LaunchAgent**: `~/Library/LaunchAgents/com.hostname.transmission.plist`
- **Completion Script**: `~/.local/bin/transmission-done.sh`
- **Download Location**: `~/.local/mnt/Media/Media/Torrents/pending-move`
- **Watch Folder**: `~/.local/sync/dropbox`

### Integration Points

- **SMB Mounting**: Relies on `mount-nas-media.sh` for download location access
- **rclone Sync**: Uses rclone sync directory for torrent file watching
- **FileBot**: Completion script prepared for media processing integration
- **Plex**: Downloads organized for media library integration

### User Customization

#### **Custom Completion Scripts**

The setup creates a default `transmission-done.sh` completion script that logs torrent completion. Users can customize this behavior:

1. **Before Setup**: Create your own `app-setup/templates/transmission-done.sh` script
   - The setup will use your custom script instead of the default template
   - Your script will be preserved across repository updates (gitignored)

2. **After Setup**: Modify the deployed script directly
   - Location: `~/.local/bin/transmission-done.sh` (on the server)
   - Changes take effect for new torrent completions
   - Script runs with full user environment and Transmission variables

**Available Environment Variables**:

```bash
TR_APP_VERSION      # Transmission version
TR_TIME_LOCALTIME   # Completion timestamp
TR_TORRENT_DIR      # Download directory path
TR_TORRENT_HASH     # Torrent hash identifier
TR_TORRENT_ID       # Transmission internal ID
TR_TORRENT_NAME     # Torrent display name
```

**Common Customizations**:

- FileBot automatic processing
- Email/notification integration  
- Cloud sync triggers
- Custom file organization
- Statistics logging
- Integration with external APIs

## Research and Development

### Preference Key Research

All preferences use verified keys from actual plist analysis. See `docs/transmission-missing-gui-settings.md` for:

- Catalogued GUI settings that cannot be automated (~10%)
- Future research directions for system integration features
- Documentation of unverified keys excluded from automation

### Quality Standards

- **Zero shellcheck warnings/errors**: Maintains project quality standards
- **Verified configuration only**: No assumed or untested preference keys  
- **Comprehensive testing**: Isolated test scripts validate all functionality
- **Documentation**: Complete coverage of automated and manual settings

## Troubleshooting

### Common Issues

**Installation Problems**:

- Verify Homebrew installation: `brew --version`
- Check cask availability: `brew search transmission`
- Review setup logs: `tail -f ~/.local/state/hostname-apps.log`

**Preference Issues**:

- Verify operator user context: `whoami`
- Check plist file: `defaults read org.m0k.transmission`
- Reset preferences: `rm ~/Library/Preferences/org.m0k.transmission.plist`

**Web Interface Access**:

- Confirm RPC settings: `defaults read org.m0k.transmission RPC`
- Test network access: `nc -zv hostname.local 19091`
- Check firewall: System Settings > Network > Firewall

**LaunchAgent Issues**:

- List loaded agents: `launchctl list | grep transmission`
- Manual load: `launchctl load ~/Library/LaunchAgents/com.hostname.transmission.plist`
- Check agent logs: `tail -f ~/.local/state/com.hostname.transmission.log`

**Magnet Link Handling**:

- Verify handler: `defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers`
- Test magnet link: `open "magnet:?xt=urn:btih:test"`
- Reset Launch Services: `sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user`

## Future Enhancements

### Potential Improvements

1. **Dock Badge Configuration**: Research correct keys for download/upload rate badges
2. **Sleep Prevention**: Investigate IOKit/Energy Saver integration
3. **System Notifications**: Explore User Notifications framework automation
4. **Theme Support**: Add dark mode and appearance customization
5. **Advanced Scheduling**: Implement time-based speed limiting

### Integration Opportunities

1. **FileBot Automation**: Enhanced completion script integration
2. **Catch Integration**: Automatic RSS feed torrent processing
3. **Monitoring Integration**: System health and transfer statistics
4. **Backup Integration**: Torrent and configuration backup automation

---

*This documentation reflects the production-ready transmission-setup.sh implementation completed on 2025-09-08.*
