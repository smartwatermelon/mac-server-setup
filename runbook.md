# Mac Mini M2 Server Setup Runbook

## Overview

This comprehensive runbook provides step-by-step instructions for setting up a Mac Mini M2 (named 'TILSIT') as a containerized application server with minimal maintenance requirements. The setup process follows these key principles:

1. **Separation of Concerns**: Base OS setup is separate from containerized applications
2. **Automation First**: Minimal human intervention throughout the lifecycle
3. **Idempotency**: Scripts can be run multiple times without causing harm
4. **Security**: Best practices for hardening and isolation
5. **Documentation**: Clear procedures for all operations

## Prerequisites

Before beginning the setup process, ensure you have:

- A Mac Mini M2 with macOS installed
- A monitor, keyboard, and mouse for initial setup
- Administrator access to the Mac Mini
- USB drive (optional, for easier transfer of scripts and SSH keys)
- Development machine with SSH keys generated

## Setup Process Overview

The setup process is divided into clearly defined phases:

1. **Preparation**: Create necessary files and scripts and AirDrop them to the Mac Mini
2. **Initial Setup**: Power on and complete the macOS setup wizard with minimal interaction
3. **First-Boot Setup**: Run the first-boot script to configure remote access and system settings
4. **Second-Boot Setup**: Install Homebrew and required packages
5. **Application Setup**: Configure containerized applications (Plex, Nginx, etc.)
6. **Monitoring Setup**: Configure system monitoring and alerts

## Detailed Steps

### 1. Preparation

#### 1.1 Prepare SSH Keys

On your development machine:

```bash
# Check if SSH keys already exist
ls -la ~/.ssh/id_ed25519*

# If keys don't exist, generate them
ssh-keygen -t ed25519 -C "your_email@example.com"
```

#### 1.2 Prepare Setup Files for AirDrop

On your development machine:

1. Create a directory for the setup files:

```bash
# Run the AirDrop preparation script
./airdrop-prep.sh ~/tilsit-setup
```

2. This script will create all necessary files in the specified directory
3. After the preparation is complete, AirDrop the entire directory to your Mac Mini

If you prefer to manually prepare the files:

```bash
# Create the directory structure
mkdir -p ~/tilsit-setup/ssh_keys
mkdir -p ~/tilsit-setup/scripts
mkdir -p ~/tilsit-setup/lists

# Copy your SSH key
cp ~/.ssh/id_ed25519.pub ~/tilsit-setup/ssh_keys/authorized_keys
cp ~/.ssh/id_ed25519.pub ~/tilsit-setup/ssh_keys/operator_authorized_keys

# Copy the scripts from your source location
cp path/to/scripts/* ~/tilsit-setup/scripts/
```

### 2. Initial Setup

#### 2.1 First Boot and macOS Setup

1. Connect the Mac Mini to power, monitor, keyboard, mouse, and network
2. Power on the Mac Mini
3. Complete the macOS setup wizard with the following settings:
   - Select your country/region
   - Connect to your Wi-Fi network
   - Sign in with your Apple ID (if desired)
   - Create an administrator account
   - Skip optional settings when possible
   - Choose minimal privacy/analytics settings

#### 2.2 Post-Setup Configuration

After reaching the desktop:

1. Look for the AirDropped `tilsit-setup` folder in your Downloads folder
2. Move it to your home directory:

```bash
mv ~/Downloads/tilsit-setup ~/
```

3. Open Terminal
4. Run the first-boot script:

```bash
# Navigate to the scripts directory
cd ~/tilsit-setup/scripts

# Make the script executable (if needed)
chmod +x first-boot.sh

# Run the script
./first-boot.sh
```

### 3. First-Boot Setup

The `first-boot.sh` script will perform the following tasks:

- Set the computer hostname to 'TILSIT'
- Enable SSH for remote access
- Create the 'operator' account
- Configure power management settings
- Set up automatic login
- Run software updates
- Create a placeholder for the second-boot script

After the script completes, the system will reboot. You should now be able to SSH into the Mac Mini from your development machine:

```bash
ssh admin_username@tilsit.local
```

### 4. Second-Boot Setup

After rebooting, log in to the Mac Mini via SSH and run the second-boot script:

```bash
# Navigate to the scripts directory
cd ~/tilsit-scripts

# Make the script executable (if needed)
chmod +x second-boot.sh

# Run the script
./second-boot.sh
```

The `second-boot.sh` script will:

- Install Homebrew from the GitHub release package
- Install the specified formulae and casks
- Set up environment paths
- Prepare for application installation

### 5. Application Setup

After the second-boot script completes, you can set up individual applications:

```bash
# Navigate to the application setup directory
cd ~/app-setup

# Set up Plex Media Server
./plex-setup.sh

# Set up Nginx web server
./nginx-setup.sh

# Set up Transmission BitTorrent client
./transmission-setup.sh
```

Each application setup script will:

- Create necessary directories
- Configure the application
- Set up the Docker container
- Provide access instructions

### 6. Monitoring Setup

Finally, set up system monitoring:

```bash
# Navigate to the scripts directory
cd ~/tilsit-scripts

# Run the monitoring setup script
./monitoring-setup.sh
```

The monitoring setup script will:

- Create health check scripts
- Configure scheduled checks
- Set up email alerts
- Create backup scripts

## Maintenance Procedures

### System Updates

To update the system:

```bash
# Update macOS
sudo softwareupdate -i -a

# Update Homebrew and packages
brew update
brew upgrade
```

### Backup

To backup configuration and important data:

```bash
# Run the backup script
~/tilsit-scripts/monitoring/backup.sh /path/to/backup/location
```

### Status Check

To check the server status:

```bash
# Run the status script
~/tilsit-scripts/monitoring/server_status.sh
```

## Troubleshooting

### SSH Connection Issues

If you can't connect via SSH:

1. Verify SSH is enabled: `sudo systemsetup -getremotelogin`
2. Check firewall settings: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`
3. Verify network connectivity: `ping tilsit.local`

### Container Issues

If Docker containers aren't working:

1. Check Docker daemon status: `docker info`
2. Check container status: `docker ps -a`
3. View container logs: `docker logs container_name`

### System Resource Issues

If the system is experiencing resource problems:

1. Check CPU usage: `top -u`
2. Check memory usage: `vm_stat`
3. Check disk usage: `df -h`

## Recovery Procedures

### Complete System Reset

If a complete reset is needed:

1. Backup important data
2. Reinstall macOS
3. Run through this setup process again

### Script Rerun

All scripts are designed to be idempotent. If issues occur, you can safely run them again:

```bash
# Rerun first-boot script (if needed)
./first-boot.sh

# Rerun second-boot script (if needed)
./second-boot.sh

# Rerun application setup scripts (if needed)
./app-setup/plex-setup.sh
```

## Conclusion

This setup creates a stable, secure, and maintainable Mac Mini server environment that:

- Requires minimal maintenance
- Runs applications in isolated containers
- Automatically monitors system health
- Provides clear procedures for all common tasks

The separation between base OS setup and containerized applications ensures that application issues don't affect the base system, and the automation-first approach minimizes the need for manual intervention throughout the server's lifecycle.
