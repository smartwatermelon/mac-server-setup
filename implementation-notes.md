# Mac Mini M2 Server Setup - Implementation Notes

## Project Overview

This document provides detailed implementation notes and technical considerations for the Mac Mini M2 server setup project. It supplements the runbook with deeper technical explanations and rationale for design decisions.

## Key Technical Design Decisions

### 1. Scripting Approach

The implementation uses bash scripting with these key features:

- **Error Handling**: `set -e` ensures scripts exit on errors
- **Logging**: Comprehensive logging to both console and log files
- **Idempotency**: All operations check current state before making changes
- **User Interaction**: Interactive prompts with force mode for automation

This approach ensures scripts are both human-friendly for manual execution and automation-ready when needed.

### 2. User Account Structure

The setup implements a two-user model:

- **Administrator Account**: Your Apple ID-linked admin account for system management
- **Operator Account**: Limited-privilege account for day-to-day operation

This separation enhances security while maintaining usability. The operator account is used for automatic login, while the admin account retains full control.

### 3. SSH Configuration

SSH is configured for secure remote access:

- Public key authentication (no password login)
- Different keys for admin and operator accounts
- Firewall rules specifically allowing SSH

This provides secure remote management while eliminating password management concerns.

### 4. Homebrew Installation

The Homebrew installation approach specifically avoids the curl-based script by:

1. Downloading the .pkg installer from GitHub releases
2. Installing via the standard installer
3. Configuring environment paths in shell configuration files

This approach provides a cleaner, more controlled installation process that can be automated.

### 5. Container Strategy

Applications are containerized using Docker with these principles:

- Each application has its own container
- Data and configuration are stored in host volumes
- The containers share a dedicated Docker network
- Containers are configured to restart automatically

This design isolates applications while maintaining data persistence and making backup straightforward.

### 6. Monitoring Approach

The monitoring system balances simplicity with effectiveness:

- Regular health checks via cron jobs
- Email-based alerting for critical issues
- Comprehensive logging for troubleshooting
- Status script for on-demand system inspection

This provides essential monitoring without complex dependencies.

## Technical Implementation Details

### Boot Process Automation

The complete boot process automation works as follows:

1. **First Boot** (requires manual interaction with macOS setup wizard)
2. **first-boot.sh**: Configures system and creates LaunchAgent
3. **Automatic Reboot**: System reboots to apply changes
4. **LaunchAgent**: Automatically runs second-boot.sh at login
5. **second-boot.sh**: Installs Homebrew and packages, prepares for applications
6. **Application Setup**: Individual application scripts set up containers

This sequence ensures each step builds on a stable foundation provided by the previous step.

### LaunchAgent Details

The LaunchAgent that triggers the second-boot script has these key properties:

- Runs at user login
- Has a daily interval (for potential reruns if needed)
- Redirects output to a log file
- Self-disables after successful execution

This provides a reliable mechanism for continuing setup after reboot without manual intervention.

### Homebrew Package Management

The Homebrew package installation uses these techniques:

- Reading package lists from text files
- Checking for existing installations before attempting to install
- Proper environment variable configuration
- Using the latest stable versions of packages

This approach is flexible, maintainable, and ideal for version control.

### Docker Configuration

The Docker setup provides these advanced features:

- Custom bridge network for inter-container communication
- Explicit port mappings for external access
- Volume mounts for persistent data
- Resource limiting capabilities (optional)
- Automatic container restart on failure or system reboot

This design balances isolation with practical container management.

### Security Considerations

Several security measures are implemented:

- Firewall enabled with specific application exceptions
- SSH using key-based authentication only
- Automatic security updates (optional)
- Limited-privilege operator account
- Secure storage of generated credentials
- TouchID sudo is enabled

These measures provide a solid security baseline for the server.

## Customization Options

The scripts include several customization points:

### 1. Media Storage Location

The Plex setup script allows customizing the media storage location. Modify the `PLEX_MEDIA_DIR` variable to point to your NAS or external drive:

```bash
PLEX_MEDIA_DIR="/Volumes/MediaDrive"  # Change to your preferred location
```

### 2. Email Alerts

The monitoring system can send email alerts. Customize the recipient address:

```bash
EMAIL_ALERTS="your.email@example.com"  # Change to your email
```

### 3. Application-Specific Configurations

Each application setup script has customizable variables:

- **Plex**: Claim token, libraries, transcoding settings
- **Nginx**: Virtual hosts, SSL configuration
- **Transmission**: Download directory, bandwidth limits

Modify these variables before running the scripts.

### 4. Hardware-Specific Optimizations

For M2 Mac Mini optimization:

- Temperature thresholds in monitoring
- Power management settings
- Performance vs. efficiency core utilization (via containerization)

## Advanced Integration Possibilities

The system design allows for these advanced integrations:

### 1. NAS Integration

Mount network storage at boot time by adding to /etc/fstab or using an automount script.

### 2. Backup System

Extend the backup script to:

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

### 4. Home Automation

Integrate with home automation by:
- Adding a Node-RED container
- Implementing MQTT for IoT communication
- Configuring HomeKit integration

## Limitations and Future Improvements

The current implementation has these limitations:

1. **No Web-Based Management Interface**: A future improvement could add a web dashboard for server management
2. **Manual macOS Updates**: Updates could be further automated with MDM tools
3. **Basic Monitoring**: Could be enhanced with more sophisticated monitoring tools
4. **Static Docker Compose**: Could be improved with dynamic configuration generation

## Technical Debt and Maintenance Considerations

Areas requiring ongoing maintenance:

1. **macOS Security Updates**: Regular review and application
2. **Docker Image Updates**: Establish a policy for container image updates
3. **Homebrew Package Management**: Regular brew update/upgrade cycles
4. **Configuration Backups**: Implement a regular backup strategy

## Conclusion

This implementation provides a robust, secure, and maintainable foundation for a Mac Mini M2 server that balances automation with the practical realities of macOS management. The separation of concerns approach makes it adaptable to changing requirements, while the containerization strategy ensures applications remain isolated from the base system.

The scripts and configuration are designed to be understood, maintained, and extended by administrators with basic bash and Docker knowledge, without relying on complex orchestration tools that would be overkill for a home server setup.
