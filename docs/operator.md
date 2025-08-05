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
ssh operator@servername.local

# Test admin SSH access  
ssh admin@servername.local
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
- **Docker Access**: Member of docker group (after application setup)
- **Application Management**: Designed for running containerized services

### Administrative Tasks

The operator account can perform most server management tasks:

```bash
# Package management
brew install <package>
brew update && brew upgrade

# Service management (after app setup)
docker-compose up -d
docker-compose restart plex

# System monitoring
brew services list
docker ps
```

### Switching to Admin Account

For system-level changes that require the original admin account:

- **Fast User Switching**: Click the username in menu bar → Switch to admin account
- **SSH Method**: `ssh admin@servername.local` from your development Mac

## Application Setup

### Application Setup Directory

The first-boot setup created `~/app-setup/` with scripts for containerized applications:

```bash
cd ~/app-setup
ls -la *.sh
```

Common application setup scripts:

- `plex-setup.sh` - Plex Media Server
- `transmission-setup.sh` - BitTorrent client  
- `monitoring-setup.sh` - System monitoring
- `caddy-setup.sh` - Web server/reverse proxy

### Running Application Installers

**Make scripts executable** (if not already):

```bash
chmod +x ~/app-setup/*.sh
```

**Run individual setup scripts**:

```bash
./plex-setup.sh
./transmission-setup.sh
```

**Follow prompts** for application-specific configuration.

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
Host servername
    HostName servername.local
    User operator
    IdentityFile ~/.ssh/id_ed25519
```

**Aliases** for common server tasks:

```bash
# Add to ~/.bash_profile
alias ll='ls -la'
alias logs='tail -f ~/.local/state/servername-setup.log'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
```

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
ssh admin@servername.local 'echo SSH working'
```

### Log Files

- **Setup logs**: `~/.local/state/servername-setup.log`
- **Application logs**: `~/app-setup/logs/` (created by app installers)
- **System logs**: Use Console.app or `log show --predicate 'processImagePath contains "your-app"'`

### Time Machine Verification

Check that backups are running properly:

- **Menu Bar**: Time Machine icon should show backup status
- **System Settings**: Apple menu → About This Mac → System Report → Software → Time Machine

## Security Considerations

### SSH Key Management

**Operator and admin accounts share SSH keys** for convenience, but you can customize this:

```bash
# Generate operator-specific SSH key
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_operator -C "operator@servername"

# Add to authorized_keys
cat ~/.ssh/id_ed25519_operator.pub >> ~/.ssh/authorized_keys
```

### Sudo Access

**TouchID is not available** for sudo commands, because TouchID cannot coexist with automatic login. For remote SSH sessions, you'll need to enter the operator password.

**Password location**: `op://personal/servername operator/password` in 1Password

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
4. **Configure monitoring** with monitoring-setup.sh
5. **Test containerized applications** after setup

### Ongoing Maintenance

- **Weekly**: Check for Homebrew updates (`brew update && brew upgrade`)
- **Monthly**: Review system logs and disk usage
- **As needed**: Update application containers and configurations

### Getting Help

- **Logs**: Most issues are logged in `~/.local/state/servername-setup.log`
- **SSH troubleshooting**: Test from development Mac first
- **Application issues**: Check individual app setup logs in `~/app-setup/logs/`

The operator account is now ready for production server management and application deployment.
