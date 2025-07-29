# Mac Mini M2 Server Setup - Implementation Notes

## Project Overview

This document provides detailed implementation notes and technical considerations for the Mac Mini M2 server setup project. It supplements the runbook with deeper technical explanations and rationale for design decisions.

## Key Technical Design Decisions

### 1. Scripting Approach

The implementation uses bash scripting with these key features:

- **Error Handling**: `set -e` ensures scripts exit on errors
- **Logging**: Comprehensive logging to both console and log files with timestamps
- **Idempotency**: All operations check current state before making changes
- **User Interaction**: Interactive prompts with `--force` mode for automation
- **Security Awareness**: Handling of sensitive information using 1Password integration

This approach ensures scripts are both human-friendly for manual execution and automation-ready when needed. The scripts leverage macOS-specific commands like `scutil`, `defaults`, and `systemsetup` to modify system configuration while maintaining compatibility with future macOS updates.

### 2. User Account Structure

The setup implements a two-user model:

- **Administrator Account**: Your Apple ID-linked admin account for system management
- **Operator Account**: Limited-privilege account for day-to-day operation with password managed in 1Password

This separation enhances security while maintaining usability. The operator account is used for automatic login, while the admin account retains full control. **The operator account password is managed through 1Password using the "TILSIT operator" entry, ensuring secure centralized credential management.**

### 3. Password Management Strategy

**1Password Integration** provides secure credential management:

- Operator passwords are managed in 1Password using the "TILSIT operator" entry
- Passwords are retrieved using `op read` command during setup preparation
- Only the password (not generation logic) is transferred to the Mac Mini
- After account creation, the password file is removed and only a reference to 1Password is stored
- This eliminates password generation complexity and verification issues

**Benefits:**

- Centralized credential management
- Reliable password verification (exact match between stored and set passwords)
- Secure storage with enterprise-grade encryption
- Easy retrieval when needed for maintenance
- No complex password generation or verification logic needed in scripts

### 4. SSH Configuration

SSH is configured for secure remote access:

- Public key authentication (no password login)
- Different keys for admin and operator accounts
- Firewall rules specifically allowing SSH
- Full Disk Access handling for Terminal if needed to enable SSH

This provides secure remote management while eliminating password management concerns. The first-boot script detects if Full Disk Access is needed and guides the user through granting it, creating a seamless experience even with macOS security restrictions.

### 5. Homebrew Installation

The Homebrew installation approach uses the official installation script:

1. Uses `NONINTERACTIVE=1` flag with the official installation script
2. Follows Homebrew's recommended post-installation steps exactly
3. Configures environment paths in shell configuration files
4. Supports both Intel and Apple Silicon architectures
5. Verifies installation with `brew help` command

This approach provides a clean, automated installation process that always gets the latest version. Package installation is handled via separate lists for formulae and casks, improving maintainability.

### 6. Container Strategy

Applications are containerized using Docker with these principles:

- Each application has its own container
- Data and configuration are stored in host volumes
- The containers share a dedicated Docker network (`tilsit-network`)
- Containers are configured to restart automatically
- Consistent environment variables across containers

This design isolates applications while maintaining data persistence and making backup straightforward. The scripts handle configuration generation and volume mapping consistently across applications.

### 7. Monitoring Approach

The monitoring system balances simplicity with effectiveness:

- Regular health checks via cron jobs (every 15 minutes)
- Email-based alerting for critical issues
- Comprehensive logging for troubleshooting
- Status script for on-demand system inspection
- Backup script for configuration and important data

The health check script monitors disk usage, CPU load, memory usage, system temperature, Docker container status, and system updates, with configurable thresholds for alerts.

## Technical Implementation Details

### Boot Process Automation

The complete boot process automation works as follows:

1. **First Boot** (requires manual interaction with macOS setup wizard)
2. **first-boot.sh**: Configures system, enables SSH, sets up accounts using 1Password credentials, installs Xcode Command Line Tools silently, installs Homebrew using official script, installs packages, prepares for applications
3. **Application Setup**: Individual application scripts set up containers

This sequence ensures each step builds on a stable foundation provided by the previous step. **The operator account creation uses credentials from the "TILSIT operator" entry in 1Password, eliminating password generation complexity and ensuring reliable authentication.**

### 1Password Integration Workflow

The 1Password integration follows this secure workflow:

1. **Preparation Phase** (`airdrop-prep.sh`):
   - Check if "TILSIT operator" credentials exist in 1Password vault
   - Create credentials if they don't exist using secure password generation
   - Retrieve password using `op read` command
   - Save password to temporary file for transfer

2. **Setup Phase** (`first-boot.sh`):
   - Read password from transferred file
   - Create operator account using this password
   - Verify password works through authentication test
   - Store reference to 1Password location (not actual password)
   - Clean up transferred password file

3. **Maintenance**:
   - Password always available via `op read "op://personal/TILSIT operator/password"`
   - Can be updated in 1Password and propagated as needed

### Homebrew Package Management

The Homebrew package installation uses these techniques:

- Reading package lists from text files (formulae.txt and casks.txt)
- Checking for existing installations before attempting to install
- Using the official Homebrew installation script with `NONINTERACTIVE=1`
- Proper environment variable configuration for different architectures
- Following Homebrew's recommended post-installation steps
- Verification using `brew help` to ensure functionality

This approach is flexible, maintainable, and ideal for version control. The scripts handle existing installations gracefully, making them safe to run multiple times.

### Docker Configuration

The Docker setup provides these advanced features:

- Custom bridge network (`tilsit-network`) for inter-container communication
- Explicit port mappings for external access
- Volume mounts for persistent data
- Automatic container restart on failure or system reboot (`--restart=unless-stopped`)
- Timezone configuration for all containers

Each application setup script checks if Docker is running, creates the network if needed, and handles container creation/starting consistently. The scripts also provide status information and access instructions after setup.

### Security Considerations

Several security measures are implemented:

- Firewall enabled with specific application exceptions
- SSH using key-based authentication only
- Automatic security updates (optional)
- Limited-privilege operator account for daily use
- **Secure credential storage in 1Password with enterprise-grade encryption using "TILSIT operator" entry**
- **No plaintext passwords stored on the server**
- Password randomization for operator account via 1Password
- TouchID sudo integration for authorized admin users

These measures provide a solid security baseline for the server, balancing security with usability. **The 1Password integration using the "TILSIT operator" entry ensures sensitive credentials are never stored in plaintext and are managed through a secure, auditable system.**

## Customization Options

The scripts include several customization points:

### 1. Media Storage Location

The Plex setup script allows customizing the media storage location. Modify the `PLEX_MEDIA_DIR` variable to point to your NAS or external drive:

```bash
PLEX_MEDIA_DIR="/Volumes/MediaDrive"  # Change to your preferred location
```

The script checks if the directory exists and creates it if needed, with appropriate permissions.

### 2. Email Alerts

The monitoring system sends email alerts. Customize the recipient address:

```bash
EMAIL_ALERTS="your.email@example.com"  # Change to your email
```

The monitoring script asks for email confirmation if not using `--force` mode and the default email is still set.

### 3. Application-Specific Configurations

Each application setup script has customizable variables:

- **Plex**: Claim token, media directory, timezone
- **Nginx**: Configuration directories, HTML content, timezone
- **Transmission**: Download directory, watch directory, credentials, timezone

Modify these variables before running the scripts. The scripts generate appropriate configurations and container settings based on these variables.

### 4. Hardware-Specific Optimizations

For M2 Mac Mini optimization:

- Temperature thresholds in monitoring (adjustable in health_check.sh)
- Power management settings for server use
- Performance vs. efficiency core utilization (via containerization)
- Disk sleep and display sleep settings

## Advanced Integration Possibilities

The system design allows for these advanced integrations:

### 1. NAS Integration

Mount network storage at boot time by adding to /etc/fstab or using an automount script. The Plex setup already supports external media storage volumes.

### 2. Backup System

The backup script can be extended to:

- Perform differential backups
- Use cloud storage (S3, Backblaze)
- Implement retention policies
- **Set up Time Machine backups to the NAS using `tmutil`** (future work)

The `tmutil` command provides powerful control over Time Machine configurations and can be used to automate backup schedules, destination management, and exclusions without requiring manual GUI interaction.

### 3. Advanced Monitoring

Enhance monitoring with:

- Prometheus + Grafana dashboards
- InfluxDB for time-series metrics
- Alertmanager for sophisticated alerting

The existing monitoring framework provides a solid foundation that can be extended with these more advanced monitoring tools if needed.

### 4. Home Automation

Integrate with home automation by:

- Adding a Node-RED container
- Implementing MQTT for IoT communication
- Configuring HomeKit integration

The server could serve as a local hub for home automation using additional containerized applications.

## Limitations and Future Improvements

The current implementation has these limitations:

1. **No Web-Based Management Interface**: A future improvement could add a web dashboard for server management
2. **Manual macOS Updates**: Updates could be further automated with MDM tools
3. **Basic Monitoring**: Could be enhanced with more sophisticated monitoring tools
4. **Static Docker Compose**: Could be improved with dynamic configuration generation or Docker Compose
5. **Limited Recovery Automation**: Disaster recovery could be further automated

## Technical Debt and Maintenance Considerations

Areas requiring ongoing maintenance:

1. **macOS Security Updates**: Regular review and application
2. **Docker Image Updates**: Establish a policy for container image updates
3. **Homebrew Package Management**: Regular brew update/upgrade cycles
4. **Configuration Backups**: Implement a regular backup strategy
5. **Security Auditing**: Periodically review security configurations and update as needed
6. **1Password Credential Rotation**: Establish policy for password rotation if required

A documented maintenance schedule would help ensure these tasks are performed regularly.

## Common Errors and Solutions

The implementation addresses several common issues:

1. **SSH Permission Issues**: Addressed by detecting and handling Full Disk Access requirements
2. **LaunchAgent Failures**: Multiple methods to register the LaunchAgent with verification
3. **Docker Network Conflicts**: Checking for existing networks before creating new ones
4. **Path Environment Issues**: Properly setting up shell environment for Homebrew
5. **Script Permission Problems**: Adding executable permissions where needed
6. **Media Directory Access**: Checking and creating directories with proper permissions
7. **Password Verification Issues**: Eliminated through 1Password integration ensuring exact password matches

## Conclusion

This implementation provides a robust, secure, and maintainable foundation for a Mac Mini M2 server that balances automation with the practical realities of macOS management. **The 1Password integration eliminates password-related complexity while ensuring enterprise-grade credential security.** The separation of concerns approach makes it adaptable to changing requirements, while the containerization strategy ensures applications remain isolated from the base system.

The scripts and configuration are designed to be understood, maintained, and extended by administrators with basic bash and Docker knowledge, without relying on complex orchestration tools that would be overkill for a home server setup.

**The 1Password integration represents a significant improvement in security and reliability**, ensuring that credentials are managed through a proven, secure system rather than ad-hoc password generation. This eliminates a major source of setup failures and maintenance complexity.

The careful attention to idempotency, error handling, and security concerns ensures that the server remains reliable and secure throughout its lifecycle, with clear procedures for setup, maintenance, and troubleshooting.
