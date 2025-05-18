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
- Development machine with SSH keys generated
- 1Password and 1Password CLI (op) configured on your development machine

## Setup Process Overview

The setup process is divided into clearly defined phases:

1. **Preparation**: Create necessary files and scripts on your development machine and AirDrop them to the Mac Mini
2. **Initial Setup**: Power on the Mac Mini and complete the macOS setup wizard with minimal interaction
3. **First-Boot Setup**: Run the first-boot script to configure remote access, system settings, and prepare for second boot
4. **Second-Boot Setup**: After automatic reboot, a LaunchAgent runs second-boot.sh to install Homebrew and required packages
5. **Application Setup**: Configure containerized applications (Plex, Nginx, Transmission)
6. **Monitoring Setup**: Configure system monitoring, health checks, and alerts

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

#### 1.2 Create TouchID Sudo Configuration (Optional)

If you want to use TouchID for sudo authentication on the Mac Mini:

```bash
# Run the script to create the TouchID sudo configuration
./create-touchid-sudo.sh
```

#### 1.3 Prepare Setup Files for AirDrop

On your development machine:

```bash
# Run the AirDrop preparation script
./airdrop-prep.sh ~/tilsit-setup
```

This script will:

- Create all necessary directories and files
- Copy your SSH keys
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
   - You can change the AirDrop setting back to "Contacts Only" for improved security
   - Verify the files are in your Downloads folder

#### 2.3 Run First-Boot Script

1. Open the Finder folder `Downloads/tilsit-setup`
2. Run the first-boot script by double-clicking the `first-boot.command` script.
3. Alternatively you can run it from Terminal:

```bash
# Navigate to the scripts directory
cd ~/Downloads/tilsit-setup/scripts

# Run the script
./first-boot.command
```

#### Mac Security Considerations
Due to macOS security restrictions, you may encounter issues running scripts on a new Mac:

1. When double-clicking `first-boot.command`, you may see a security warning
2. To proceed, right-click (or Control+click) the file and select "Open"
3. Click "Open" in the security dialog that appears
4. Alternatively, you can run the script from Terminal:

   ```bash
   cd ~/Downloads/tilsit-setup/scripts
   chmod +x first-boot.command
   ./first-boot.command
   ```

### 3. First-Boot Setup

The `first-boot.command` script will perform the following tasks:

- Set the computer hostname and HD name to 'TILSIT'
- Enable SSH for remote access (may require Full Disk Access)
- Configure TouchID for sudo (if available)
- Fix scroll direction setting to natural
- Set up WiFi (if configuration is available)
- Set up SSH keys for secure authentication
- Configure Apple ID (see steps below)
- Create the 'operator' account with a secure random password
- Configure power management settings for server use
- Set up temporary automatic login for the admin account
- Configure the firewall
- Run software updates
- Create a LaunchAgent for the second-boot script
- Reboot the system

#### 3.1 Apple ID Configuration During First-Boot

During the execution of `first-boot.command`, you'll need to manually configure your Apple ID:

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

#### 3.3 After First-Boot Completion

After the script completes, the system will reboot. You should now be able to SSH into the Mac Mini from your development machine:

```bash
ssh admin_username@tilsit.local
```

You may configure passwordless SSH from your development machine:

```bash
ssh-copy-id admin_username@tilsit.local
```

### 4. Second-Boot Setup

The `second-boot.sh` script will run automatically after reboot via the LaunchAgent. It will:

- Install Homebrew from the GitHub release package
- Install the specified formulae and casks from the provided lists
- Set up environment paths in shell configuration files
- Prepare the application setup directory
- Switch automatic login from admin to operator user
- Disable its own LaunchAgent to prevent future runs

To verify the script has run successfully, check the log file:

```bash
cat ~/.local/state/tilsit-setup.log
```

If you need to run the script manually:

```bash
# Navigate to the scripts directory
cd ~/tilsit-scripts

# Make the script executable (if needed)
chmod +x second-boot.sh

# Run the script
./second-boot.sh
```

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
- Create a Docker network (tilsit-network) if it doesn't exist
- Provide access instructions
- Handle restart settings for the container

### 6. Monitoring Setup

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
./first-boot.command

# Rerun second-boot script (if needed)
./second-boot.sh

# Rerun application setup scripts (if needed)
./app-setup/plex-setup.sh
```

### Operator Account Password Recovery

If you need to recover the operator account password:

1. Login as the admin user
2. Check the password file: `cat ~/Documents/operator_password.txt`

## Conclusion

This setup creates a stable, secure, and maintainable Mac Mini server environment that:

- Requires minimal maintenance
- Runs applications in isolated containers
- Automatically monitors system health
- Provides clear procedures for all common tasks
- Uses Docker for consistent application deployment
- Implements security best practices

The separation between base OS setup and containerized applications ensures that application issues don't affect the base system, and the automation-first approach minimizes the need for manual intervention throughout the server's lifecycle.
