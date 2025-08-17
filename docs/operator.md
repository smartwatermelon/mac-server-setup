# Operator Setup Instructions

After the first reboot, the Mac Mini automatically logs in as the **operator** user. This non-administrator account is designed for day-to-day server operations and application management.

## Initial Operator Login

### Automatic Login

The system is configured to automatically log in as the operator user after reboot. You should see:

- **Desktop with clean dock** (minimal applications)
- **"dock-cleanup.command" file** on the desktop
- **Fast User Switching menu** in the menu bar (showing current user)

## Required First Steps

### 1. Clean Up Dock

**Double-click "dock-cleanup.command"** on the desktop to remove unnecessary applications from the dock.

This script removes messaging apps, media apps, and other consumer-focused applications that aren't needed on a server, while adding essential tools like iTerm and Passwords.

### 2. Verify SSH Access

Test SSH connectivity from your development Mac:

```bash
# Test operator SSH access
ssh operator@macmini.local

# Test admin SSH access  
ssh admin@macmini.local
```

Both accounts should accept SSH key authentication without password prompts.

### 3. Switch to iTerm (Recommended)

The dock cleanup adds iTerm to the dock. **Switch from Terminal to iTerm** for better server management:

- **Launch iTerm** from dock or Applications
- **Better color support** for logs and status messages
- **Improved session management** for long-running tasks

## Account Capabilities

### Operator Account Features

- **SSH Key Authentication**: Same SSH keys as admin account
- **Homebrew Access**: Full access to package management
- **Application Access**: Access to shared application configurations via staff group membership
- **Native Application Management**: Designed for running native macOS applications with shared configuration access

### Administrative Tasks

The operator account can perform most server management tasks:

```bash
# Package management
brew install <package>
brew update && brew upgrade

# Native application management (after app setup)
launchctl list | grep plex
launchctl stop com.plexapp.plexmediaserver
launchctl start com.plexapp.plexmediaserver

# System monitoring
brew services list
ps aux | grep "Plex Media Server"
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
- `caddy-setup.sh` - Web server/reverse proxy (planned)

### Running Application Installers

**Make scripts executable** (if not already):

```bash
chmod +x ~/app-setup/*.sh
```

**Run individual setup scripts**:

```bash
./plex-setup.sh
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

# Check Plex launch agent status
launchctl list | grep com.plexapp.plexmediaserver

# Manually start/stop applications
launchctl stop com.plexapp.plexmediaserver
launchctl start com.plexapp.plexmediaserver
```

**Accessing Applications**:

- **Plex Web Interface**: `http://macmini.local:32400/web`
- **Direct access**: Applications run under operator account with shared config access

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
- **Plex logs**: `/tmp/plex-out.log` and `/tmp/plex-error.log`
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

**TouchID is not available** for sudo commands, because TouchID cannot coexist with automatic login. For remote SSH sessions, you'll need to enter the operator password.

**Password location**: `op://personal/operator/password` in 1Password

### Firewall Status

Verify firewall is active and properly configured:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps
```

## Next Steps

### Immediate Tasks

1. **✅ Run dock-cleanup.command**
2. **✅ Verify SSH access**  
3. **Run application setup scripts** as needed
4. **Configure additional services** as needed
5. **Test native applications** after setup (check LaunchAgent status)

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
