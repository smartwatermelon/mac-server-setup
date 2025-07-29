# Mac Mini M2 Server Setup Runbook

## Overview

This comprehensive runbook provides step-by-step instructions for setting up a Mac Mini M2 (named 'TILSIT') as a containerized application server with minimal maintenance requirements. The setup process follows these key principles:

1. **Separation of Concerns**: Base OS setup is separate from containerized applications
2. **Automation First**: Minimal human intervention throughout the lifecycle
3. **Idempotency**: Scripts can be run multiple times without causing harm
4. **Security**: Best practices for hardening and isolation using 1Password for credential management
5. **Documentation**: Clear procedures for all operations

## Prerequisites

Before beginning the setup process, ensure you have:

- A Mac Mini M2 with macOS installed
- A monitor, keyboard, and mouse for initial setup
- Administrator access to the Mac Mini
- Development machine with SSH keys generated
- **1Password and 1Password CLI (`op`) configured on your development machine**
- **1Password CLI authenticated and ready to use**

## Setup Process Overview

The setup process is divided into clearly defined phases:

1. **Preparation**: Create necessary files and scripts on your development machine and AirDrop them to the Mac Mini
2. **Initial Setup**: Power on the Mac Mini and complete the macOS setup wizard with minimal interaction
3. **First-Boot Setup**: Run the first-boot script to configure remote access, system settings, and install Homebrew and required packages
4. **Application Setup**: Configure containerized applications (Plex, Nginx, Transmission)
5. **Monitoring Setup**: Configure system monitoring, health checks, and alerts

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

#### 1.2 Verify 1Password CLI Setup

Ensure 1Password CLI is properly configured:

```bash
# Check if op CLI is installed and authenticated
op account list

# If not authenticated, sign in
op signin
```

#### 1.3 Create TouchID Sudo Configuration (Optional)

If you want to use TouchID for sudo authentication on the Mac Mini:

```bash
# Run the script to create the TouchID sudo configuration
./create-touchid-sudo.sh
```

#### 1.4 Prepare Setup Files for AirDrop

On your development machine:

```bash
# Run the AirDrop preparation script
./airdrop-prep.sh ~/tilsit-setup
```

This script will:

- Create all necessary directories and files
- Copy your SSH keys
- **Check for existing "TILSIT operator" credentials in 1Password or create them**
- **Retrieve the operator password from 1Password for transfer**
- Generate a one-time password link for your Apple ID using 1Password
- Copy setup scripts and package lists
- Create a README with setup instructions
- Optionally configure WiFi by storing your current network's credentials
- Set up TouchID sudo configuration if available

### 2. Initial Setup

#### 2.1 First Boot and macOS Setup

1. Connect the Mac Mini to power, monitor, keyboard, mouse, and network
2. Power on the Mac Mini
3. Complete the macOS setup wizard with the following settings:
   - Select your country/region
   - When prompted to sign in with your Apple ID, choose "Set Up Later" (we'll do this during the first-boot script)
   - Create an administrator account
   - Skip optional settings when possible
   - Choose minimal privacy/analytics settings

#### 2.2 Enable AirDrop and Transfer Files

After reaching the desktop:

1. Enable AirDrop for file transfer:
   - Open **Finder** from the Dock and click on **AirDrop** in the sidebar OR press **Cmd-Shift-R** from the Desktop
   - At the bottom of the window, click on "Allow me to be discovered by:" and select **Everyone**
   - Keep this window open

2. On your development machine:
   - Ensure the AirDrop preparation script has completed
   - Use AirDrop to send the entire `tilsit-setup` folder to your Mac Mini
   - On the Mac Mini, accept the incoming AirDrop transfer

3. After the transfer completes:
   - Verify the files are in your Downloads folder

#### 2.3 Run First-Boot Script

1. Open the Finder folder `Downloads/tilsit-setup`
2. Right-click the `scripts` folder and select **New Terminal at Folder**
3. Run the first-boot script:

```bash
./first-boot.sh
```

### 3. First-Boot Setup

The `first-boot.sh` script will perform the following tasks:

- Set the computer hostname and HD name
- Enable SSH for remote access (may require Full Disk Access)
- Configure TouchID for sudo (if available)
- Fix scroll direction setting to natural
- Set up WiFi (if configuration is available)
- Set up SSH keys for secure authentication
- Configure Apple ID (see steps below)
- **Create the 'operator' account using the password from 1Password**
- Configure power management settings for server use
- Configure the firewall
- **Install Xcode Command Line Tools silently**
- **Install Homebrew using the official installation script**
- **Apply Homebrew's recommended PATH configuration**
- Install the specified formulae and casks from the provided lists
- Set up environment paths in shell configuration files
- Prepare the application setup directory

To verify the script has run successfully, check the log file:

```bash
cat ~/.local/state/tilsit-setup.log
```

If you need to re-run the script manually:

```bash
# Navigate to the scripts directory
cd ~/tilsit-scripts

# Run the script
./first-boot.sh
```

#### 3.1 Apple ID Configuration During First-Boot

During the execution of `first-boot.sh`, you'll need to manually configure your Apple ID:

1. The script will open the Apple ID one-time password link in your default browser
2. In the browser:
   - Copy your Apple ID password from the one-time link page (the link will expire after use)

3. The script will then open System Settings to the Apple ID section
4. In System Settings:
   - Enter your Apple ID email address
   - Paste the copied password
   - Complete any verification steps (such as two-factor authentication)
   - Select which services you want to enable (consider enabling only essential services)

5. Return to Terminal and press any key to continue the script

#### 3.2 Full Disk Access Consideration

If the script cannot enable SSH directly, it will:

1. Request Full Disk Access for Terminal
2. Guide you through this process with clear instructions
3. Create a marker file to detect when it's re-run
4. After adding Terminal to FDA, close the Terminal window and run the script again

#### 3.3 Operator Account Setup

The script will:

1. **Read the operator password from the transferred 1Password file**
2. **Create the operator account using this password**
3. **Verify the password works by testing authentication**
4. **Store a reference to the 1Password location (not the actual password)**
5. **Clean up the transferred password file for security**

#### 3.4 After First-Boot Completion

After the script completes, the system will reboot. You should now be able to SSH into the Mac Mini from your development machine:

```bash
# Using the admin account
ssh admin_username@tilsit.local

# Or using the operator account with the password from 1Password
ssh operator@tilsit.local
```

You may configure passwordless SSH from your development machine:

```bash
ssh-copy-id admin_username@tilsit.local
ssh-copy-id operator@tilsit.local
```

### 4. Application Setup

After the first-boot script completes, you can set up individual applications:

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
- Create a Docker network (tilsit-network) if it doesn't exist
- Provide access instructions
- Handle restart settings for the container

### 5. Monitoring Setup

Finally, set up system monitoring:

```bash
# Navigate to the scripts directory
cd ~/tilsit-scripts

# Run the monitoring setup script
./monitoring-setup.sh
```

The monitoring setup script will:

- Create health check scripts that monitor:
  - Disk usage
  - CPU load
  - Memory usage
  - System temperature
  - Docker container status
  - System updates
- Configure scheduled checks via cron
- Set up email alerts for critical issues
- Create status and backup scripts

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

### Password Management

**Operator account password** is managed through 1Password:

```bash
# Retrieve the current operator password
op read "op://personal/TILSIT operator/password"

# Update the password if needed (on development machine)
op item edit "TILSIT operator" --vault personal password="new_password"
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

### Monitoring Health Check Results

To view recent monitoring results and alerts:

```bash
# View the monitoring log
cat ~/.local/state/tilsit-monitoring.log
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
4. Verify Docker network exists: `docker network inspect tilsit-network`

### System Resource Issues

If the system is experiencing resource problems:

1. Check CPU usage: `top -u`
2. Check memory usage: `vm_stat`
3. Check disk usage: `df -h`
4. View latest health check results: `cat ~/.local/state/tilsit-monitoring.log`

### Password Issues

**Operator account password problems:**

1. Verify password in 1Password: `op read "op://personal/TILSIT operator/password"`
2. Test authentication: `dscl /Local/Default -authonly operator $(op read "op://personal/TILSIT operator/password")`
3. Reset password if needed: `sudo dscl . -passwd /Users/operator $(op read "op://personal/TILSIT operator/password")`

## Recovery Procedures

### Complete System Reset

If a complete reset is needed:

1. Backup important data using the backup script
2. Reinstall macOS
3. Run through this setup process again

### Script Rerun

All scripts are designed to be idempotent. If issues occur, you can safely run them again:

```bash
# Rerun first-boot script (if needed)
./first-boot.sh

# Rerun application setup scripts (if needed)
./app-setup/plex-setup.sh
```

### Operator Account Password Recovery

**The operator account password is always available from 1Password:**

1. From your development machine: `op read "op://personal/TILSIT operator/password"`
2. Or through the 1Password app/web interface at: `op://personal/TILSIT operator/password`

## Conclusion

This setup creates a stable, secure, and maintainable Mac Mini server environment that:

- Requires minimal maintenance
- Runs applications in isolated containers
- Automatically monitors system health
- Provides clear procedures for all common tasks
- Uses Docker for consistent application deployment
- Implements security best practices with centralized credential management
- **Leverages 1Password for secure, reliable password management**

The separation between base OS setup and containerized applications ensures that application issues don't affect the base system, and the automation-first approach minimizes the need for manual intervention throughout the server's lifecycle. **1Password integration ensures passwords are securely managed and easily retrievable when needed.**
