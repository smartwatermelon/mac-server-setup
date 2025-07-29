# Mac Mini M2 Server Setup Runbook

## Overview

This runbook provides step-by-step instructions for setting up a Mac Mini M2 (named 'TILSIT') as a containerized application server. The setup is designed to be run once successfully with minimal ongoing maintenance.

## Key Principles

1. **Run Once**: Scripts are designed for one-time setup, not ongoing system management
2. **Simple and Reliable**: Minimal complexity, maximum reliability
3. **1Password Integration**: Secure credential management using existing 1Password vault
4. **Automation First**: Minimal human intervention during setup
5. **Clear Documentation**: Straightforward procedures for setup and basic maintenance

## Prerequisites

Before beginning setup:

- Mac Mini M2 with macOS installed
- Monitor, keyboard, and mouse for initial setup
- Administrator access to the Mac Mini
- Development machine with SSH keys generated
- **1Password and 1Password CLI (`op`) configured and authenticated on development machine**
- Network connectivity for both machines

## Setup Process Overview

1. **Preparation**: Create setup files on development machine using `airdrop-prep.sh`
2. **Initial macOS Setup**: Complete macOS setup wizard on Mac Mini
3. **File Transfer**: AirDrop setup files to Mac Mini
4. **First-Boot Setup**: Run `first-boot.sh` to configure system and install packages
5. **Application Setup**: Configure containerized applications as needed

## Detailed Steps

### 1. Preparation

#### 1.1 Verify Prerequisites

Ensure SSH keys exist on development machine:

```bash
ls -la ~/.ssh/id_ed25519*
# If not found: ssh-keygen -t ed25519 -C "your_email@example.com"
```

Verify 1Password CLI is authenticated:

```bash
op account list
# If not authenticated: op signin
```

#### 1.2 Prepare Setup Files

Run the preparation script:

```bash
./airdrop-prep.sh ~/tilsit-setup
```

This script will:

- Create directory structure for setup files
- Copy SSH keys for secure access
- **Check for "TILSIT operator" credentials in 1Password or create them**
- **Retrieve operator password for transfer**
- Configure WiFi using current network credentials
- Copy scripts and package lists
- Create setup instructions

### 2. macOS Setup on Mac Mini

1. Connect Mac Mini to power, monitor, keyboard, mouse, and network
2. Power on and complete macOS setup wizard:
   - Select country/region
   - Choose "Set Up Later" for Apple ID (handled by script)
   - Create administrator account
   - Skip optional settings
   - Choose minimal privacy/analytics settings

### 3. File Transfer

1. On Mac Mini, enable AirDrop:
   - Open Finder → AirDrop (or Cmd-Shift-R)
   - Set "Allow me to be discovered by: Everyone"

2. From development machine:
   - AirDrop the entire `tilsit-setup` folder to Mac Mini
   - Accept transfer on Mac Mini (files go to Downloads)

### 4. First-Boot Setup

1. On Mac Mini, open Terminal and navigate to setup files:

```bash
cd ~/Downloads/tilsit-setup/scripts
chmod +x first-boot.sh
./first-boot.sh
```

The script will automatically:

- Set hostname and HD volume name
- Fix scroll direction setting
- Configure WiFi using transferred credentials
- Enable SSH with Full Disk Access guidance if needed
- **Create operator account using 1Password credentials**
- Configure power management for server use
- Configure firewall settings
- **Install Xcode Command Line Tools silently**
- **Install Homebrew using official installation script**
- **Apply Homebrew's recommended PATH configuration**
- Install packages from formulae.txt and casks.txt
- Prepare application setup directory

#### 4.1 Apple ID Configuration

During script execution:

- Script opens one-time Apple ID password link
- Script opens System Settings to Apple ID section
- Complete Apple ID setup manually:
  - Enter Apple ID and password
  - Handle two-factor authentication
  - Select desired services
  - Return to Terminal when complete

#### 4.2 Full Disk Access (if needed)

If SSH setup requires Full Disk Access:

- Script opens Finder to Terminal.app location
- Script opens System Settings to Full Disk Access
- Drag Terminal from Finder to Full Disk Access list
- Close Terminal window and relaunch script

### 5. Application Setup

After first-boot completion:

```bash
cd ~/app-setup

# Setup applications as needed
./plex-setup.sh
./nginx-setup.sh
./transmission-setup.sh
```

### 6. Monitoring Setup

Configure system monitoring:

```bash
cd ~/tilsit-scripts
./monitoring-setup.sh
```

## Post-Setup Access

After setup completion:

**SSH Access**:

```bash
# Using admin account
ssh your_admin_username@tilsit.local

# Using operator account
ssh operator@tilsit.local
```

**Operator Password**: Available in 1Password at `op://personal/TILSIT operator/password`

## Basic Maintenance

### System Updates

```bash
# macOS updates
sudo softwareupdate -i -a

# Homebrew updates
brew update && brew upgrade
```

### Password Management

Operator account password is managed in 1Password:

```bash
# Retrieve password
op read "op://personal/TILSIT operator/password"

# Update password if needed (on development machine)
op item edit "TILSIT operator" --vault personal password="new_password"
```

### Container Management

```bash
# Check container status
docker ps -a

# View container logs
docker logs container_name

# Restart container
docker restart container_name
```

## Troubleshooting

### SSH Connection Issues

1. Verify SSH enabled: `sudo systemsetup -getremotelogin`
2. Check firewall: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`
3. Test connectivity: `ping tilsit.local`

### Package Installation Issues

1. Check Homebrew: `brew doctor`
2. Update package lists: `brew update`
3. Check Xcode CLT: `xcode-select -p`

### Password Issues

1. Verify in 1Password: `op read "op://personal/TILSIT operator/password"`
2. Test authentication: `dscl /Local/Default -authonly operator $(op read "op://personal/TILSIT operator/password")`

### Container Issues

1. Check Docker: `docker info`
2. Check network: `docker network ls`
3. Restart Docker: `sudo launchctl unload /Library/LaunchDaemons/com.docker.vmnetd.plist && sudo launchctl load /Library/LaunchDaemons/com.docker.vmnetd.plist`

## Recovery

### Script Re-run

Scripts are idempotent and can be safely re-run:

```bash
# Re-run first-boot if needed
./first-boot.sh

# Re-run specific app setup
./app-setup/plex-setup.sh
```

### Password Recovery

Operator password is always available from 1Password:

- CLI: `op read "op://personal/TILSIT operator/password"`
- 1Password app: Search for "TILSIT operator"

### Complete Reset

1. Backup important data
2. Reinstall macOS
3. Run setup process again

## Notes

- Setup is designed for one-time execution
- All credentials managed through 1Password
- Scripts handle common errors and permission requirements
- Documentation assumes basic familiarity with Terminal and SSH
- For complex issues, refer to script logs in `~/.local/state/tilsit-setup.log`
