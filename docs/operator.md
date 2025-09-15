# Operator Setup Instructions

After the first reboot, the Mac Mini automatically logs in as the **operator** user. This non-administrator account is designed for day-to-day server operations and application management.

## Initial Operator Login

### Automatic Login

The system is configured to automatically log in as the operator user after reboot. You should see:

- **Automatic dock customization** (happens in background on first login)
- **Desktop with clean dock** (iTerm, Plex, essential apps)
- **Fast User Switching menu** in the menu bar (showing current user)

## Automatic Setup

### 1. First-Login Customization

**Dock cleanup happens automatically** when you first log in as the operator. A LaunchAgent runs in the background to:

- Remove unnecessary applications (Messages, Mail, Maps, etc.)
- Add essential server tools (iTerm, Plex Media Server, Passwords)
- Add network media folder (if SMB mount is available)

You can monitor the setup progress in the logs:

```bash
tail -f ~/.local/state/*-operator-login.log
```

### 2. Manual Re-run (if needed)

If you need to re-run the first-login customization:

```bash
~/.local/bin/operator-first-login.sh
```

### 3. Verify SSH Access

Test SSH connectivity from your development Mac:

```bash
# Test operator SSH access
ssh operator@macmini.local

# Test admin SSH access
ssh admin@macmini.local
```

Both accounts should accept SSH key authentication without password prompts.

### 4. Switch to iTerm (Recommended)

The automatic setup adds iTerm to the dock. **Switch from Terminal to iTerm** for better server management:

- **Launch iTerm** from dock (added automatically)
- **Better color support** for logs and status messages
- **Improved session management** for long-running tasks

## Account Capabilities

### Operator Account Features

- **SSH Key Authentication**: Same SSH keys as admin account
- **Homebrew Access**: Full access to package management
- **Application Access**: Access to shared application configurations via staff group membership
- **Native Application Management**: Designed for running native macOS applications with shared configuration access
- **Direct SMB Access**: Access to mounted network shares for media management

### Administrative Tasks

The operator account can perform some server management tasks:

```bash
# Native application management (after app setup)
launchctl list | grep plex
launchctl stop com.plexapp.plexmediaserver
launchctl start com.plexapp.plexmediaserver

# System monitoring
brew services list
ps aux | grep "Plex Media Server"
```

The administrator account must be used for package installation:

```bash
# Package management
brew install <package>
brew update && brew upgrade
```

### Switching to Admin Account

For system-level changes that require the original admin account:

- **Fast User Switching**: Click the username in menu bar → Switch to admin account
- **SSH Method**: `ssh admin@macmini.local` from your development Mac

## Application Setup

### Application Setup Directory

The first-boot setup created `~/app-setup/` with scripts for native macOS applications:

```bash
cd ~/app-setup
ls -la *.sh
```

Common application setup scripts:

- `plex-setup.sh` - Native Plex Media Server installation and configuration
- `rclone-setup.sh` - Dropbox synchronization for media file management
- `transmission-setup.sh` - BitTorrent client with automated GUI configuration and magnet link handling
- `run-app-setup.sh` - Orchestrator script to install all applications in dependency order
- `caddy-setup.sh` - Web server/reverse proxy (planned)

### Running Application Installers

**Make scripts executable** (if not already):

```bash
chmod +x ~/app-setup/*.sh
```

**Run all applications (recommended)**:

```bash
# Automated deployment of all applications in dependency order
./run-app-setup.sh

# Skip confirmations for unattended operation
./run-app-setup.sh --force
```

**Run individual setup scripts**:

```bash
./plex-setup.sh
./rclone-setup.sh
./transmission-setup.sh
```

**Follow prompts** for application-specific configuration:

- Most prompts default to Yes (Y/n) - press Enter to proceed
- Use `--force` flag to skip all prompts: `./plex-setup.sh --force`
- **Note**: Application setup scripts run as administrator and configure shared access for operator

## Customizing the Environment

### Shell Configuration

The operator account uses **Homebrew bash** as the default shell with enhanced features:

- **Liquidprompt**: Enhanced command prompt with git status, system info
- **Homebrew packages**: Access to modern versions of common tools
- **Bash completion**: Tab completion for common commands

### Adding Personal Configurations

**SSH Config** for easier server access:

```bash
# ~/.ssh/config
Host macmini
    HostName macmini.local
    User operator
    IdentityFile ~/.ssh/id_ed25519
```

**Aliases** for common server tasks:

```bash
# Add to ~/.bash_profile
alias ll='ls -la'
alias logs='tail -f ~/.local/state/macmini-setup.log'
alias plex-status='ps aux | grep "Plex Media Server" | grep -v grep'
alias plex-logs='tail -f /tmp/plex-out.log /tmp/plex-error.log'
```

## Application Configuration Access

### Shared Configuration Directory

Native applications store their configurations in shared directories accessible to both admin and operator users:

**Plex Media Server Configuration**:

- **Location**: `/Users/Shared/PlexMediaServer/`
- **Access**: Read/write access via staff group membership
- **Ownership**: `admin:staff` with `775` permissions

**Transmission Configuration**:

- **Auto-configured**: Download paths, seeding limits, peer settings, blocklist, RPC access, magnet link handling
- **Web Interface**: `http://macmini.local:19091` (username: macmini, password: macmini)
- **LaunchAgent**: Starts automatically on operator login
- **Manual setup required**: See "Transmission Settings" section below

**Accessing Shared Configurations**:

```bash
# View Plex configuration directory
ls -la /Users/Shared/PlexMediaServer/

# Check your group membership (should include 'staff')
groups

# View application-specific configs
ls -la /Users/Shared/PlexMediaServer/Plex\ Media\ Server/
```

### Application Management

**Launch Agents**: Applications are configured to start automatically with operator login via LaunchAgents in `~/Library/LaunchAgents/`:

```bash
# View configured launch agents
ls -la ~/Library/LaunchAgents/

# Check launch agent status
launchctl list | grep com.plexapp.plexmediaserver
launchctl list | grep transmission

# Manually start/stop applications
launchctl stop com.plexapp.plexmediaserver
launchctl start com.plexapp.plexmediaserver
# Note: Transmission starts via 'open -a Transmission' LaunchAgent
```

**Accessing Applications**:

- **Plex Web Interface**: `http://macmini.local:32400/web`
- **Transmission Web Interface**: `http://macmini.local:19091`
- **Direct access**: Applications run under operator account with shared config access

### Transmission Settings

**Settings that can't be configured automatically** (must be set manually on first login):

**General Tab**:

- **Notifications**: Click "Configure in System Preferences" for system notifications

**Network Tab**:

- **System sleep**: "Prevent computer from sleeping with active transfers" (if desired)

**Note**: All core BitTorrent functionality (downloads, seeding, peer settings, blocklist, magnet link handling) is pre-configured automatically.

## Monitoring and Maintenance

### System Status Checks

**Homebrew health**:

```bash
brew doctor
brew outdated
```

**Disk usage**:

```bash
df -h
du -sh ~/Downloads ~/Documents
```

**Network connectivity**:

```bash
ping google.com
ssh admin@macmini.local 'echo SSH working'
```

### Log Files

- **Setup logs**: `~/.local/state/macmini-setup.log`
- **Application setup logs**: `~/.local/state/macmini-apps.log`
- **Plex logs**: `/Users/Shared/PlexMediaServer/Plex Media Server/Logs`
- **System logs**: Use Console.app or `log show --predicate 'processImagePath contains "Plex Media Server"'`

### Time Machine Verification

Check that backups are running properly:

- **Menu Bar**: Time Machine icon should show backup status
- **System Settings**: Apple menu → About This Mac → System Report → Software → Time Machine

## Security Considerations

### SSH Key Management

**Operator and admin accounts share SSH keys** for convenience, but you can customize this:

```bash
# Generate operator-specific SSH key
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_operator -C "operator@macmini"

# Add to authorized_keys
cat ~/.ssh/id_ed25519_operator.pub >> ~/.ssh/authorized_keys
```

### Sudo Access

**TouchID is not available** for sudo commands, because TouchID cannot coexist with automatic login.

**Password location**: `op://personal/operator/password` in 1Password

### Firewall Status

Verify firewall is active and properly configured:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps
```

## Next Steps

### Immediate Tasks

1. **✅ Automatic dock customization** (happens on first login)
2. **✅ Verify SSH access**
3. **Run application setup scripts** as needed (as admin user)
4. **Configure additional services** as needed
5. **Test native applications** after setup (check LaunchAgent status)

**Note for Plex Migration Users**: If your server was set up via Plex migration, you may need to re-pin your media libraries to restore your customized home screen. Access `http://macmini.local:32400/web`, click "More" in the sidebar, and pin your libraries back to the home screen.

### Ongoing Maintenance

- **Weekly**: Check for Homebrew updates (`brew update && brew upgrade`)
- **Monthly**: Review system logs and disk usage
- **As needed**: Update native applications and shared configurations

### Getting Help

- **Logs**: Most issues are logged in `~/.local/state/macmini-setup.log` and `~/.local/state/macmini-apps.log`
- **SSH troubleshooting**: Test from development Mac first
- **Application issues**: Check LaunchAgent status and application-specific logs
- **Shared config issues**: Verify staff group membership and directory permissions

The operator account is now ready for production server management and application deployment.
