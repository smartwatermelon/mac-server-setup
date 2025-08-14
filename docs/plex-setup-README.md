# Plex Setup Script Documentation

This document describes the operation, configuration, and troubleshooting of the `plex-setup.sh` script for Mac Mini M2 server setup.

## Overview

The `plex-setup.sh` script automates the deployment of Plex Media Server in a Docker container with:

- SMB mount to NAS for media storage
- Configuration migration from existing Plex server
- Auto-start configuration for the operator user
- Integration with the server's configuration system

## Script Location and Usage

**Script Path**: `./app-setup/plex-setup.sh`

**Basic Usage**:

```bash
# Run from the server setup directory
./app-setup/plex-setup.sh [OPTIONS]
```

**Command Line Options**:

- `--force`: Skip all confirmation prompts (unattended installation)
- `--skip-migration`: Skip Plex configuration migration
- `--skip-mount`: Skip SMB mount setup

**Examples**:

```bash
# Full interactive setup with migration
./app-setup/plex-setup.sh

# Unattended fresh installation
./app-setup/plex-setup.sh --force --skip-migration

# Setup without NAS mounting (mount manually later)
./app-setup/plex-setup.sh --skip-mount
```

## Configuration Sources

The script derives its configuration from multiple sources in the following priority order:

### 1. Server Configuration File

**Source**: `../config.conf` (relative to script location)

**Key Variables Used**:

- `SERVER_NAME`: Primary server identifier
- `OPERATOR_USERNAME`: Non-admin user account name
- `HOSTNAME_OVERRIDE`: Custom hostname (optional)
- `DOCKER_NETWORK_OVERRIDE`: Custom Docker network name (optional)

**Derived Variables**:

```bash
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
DOCKER_NETWORK="${DOCKER_NETWORK_OVERRIDE:-${HOSTNAME_LOWER}-network}"
```

### 2. Hard-coded Script Configuration

**NAS Configuration**:

- `NAS_SMB_URL="smb://plex@pecorino.local/DSMedia"`
- `PLEX_MEDIA_MOUNT="/Volumes/DSMedia"`

**Docker Configuration**:

- `PLEX_CONTAINER_NAME="${HOSTNAME_LOWER}-plex"`
- Docker image: `lscr.io/linuxserver/plex:latest`
- Timezone: `America/Los_Angeles` (customizable in script)

**Directory Paths**:

- `PLEX_CONFIG_DIR="${HOME}/Docker/plex/config"`
- `PLEX_MIGRATION_DIR="${HOME}/plex-migration"`
- `LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-apps.log"`

### 3. Runtime Configuration

**User Input** (when not using `--force`):

- Plex claim token (for fresh installations)
- Confirmation prompts for each major operation
- NAS mounting credentials (via macOS GUI)

## Expected File Structure

### Plex Migration Files

If migrating from an existing Plex server, place files at:

```plaintext
~/plex-migration/
├── Plex Media Server/          # Complete config directory from old server
│   ├── Plug-in Support/
│   ├── Metadata/
│   ├── Media/
│   ├── Logs/
│   └── ... (all subdirectories except Cache)
└── com.plexapp.plexmediaserver.plist   # macOS preferences (optional)
```

**How to Obtain These Files**:

1. **From macOS Plex Server**:

   ```bash
   # On the old server, copy the main directory
   cp -R "~/Library/Application Support/Plex Media Server" ~/migration-backup/
   
   # Copy the preferences file
   cp "~/Library/Preferences/com.plexapp.plexmediaserver.plist" ~/migration-backup/
   
   # Transfer to new server at ~/plex-migration/
   ```

2. **Exclude Cache Directory** (recommended for faster transfer):

   ```bash
   rsync -av --exclude='Cache' "~/Library/Application Support/Plex Media Server/" ~/migration-backup/
   ```

### Generated Directory Structure

After script execution:

```plaintext
~/Docker/plex/
└── config/                     # Plex configuration (mapped to container)
    ├── Library/                # Plex application data
    ├── Logs/                   # Plex logs
    └── ... (Plex directory structure)

/Users/${OPERATOR_USERNAME}/Library/LaunchAgents/
└── local.plex.docker.plist     # Auto-start configuration

~/.local/state/
└── ${HOSTNAME_LOWER}-apps.log  # Script execution log
```

## Operation Flow

### Phase 1: Initialization

1. **Load Configuration**: Sources `../config.conf` and derives variables
2. **Parse Arguments**: Processes command-line flags
3. **Validate Prerequisites**: Checks Docker availability
4. **User Confirmation**: Prompts for operation confirmation (unless `--force`)

### Phase 2: NAS Mount Setup

1. **Check Existing Mount**: Verifies if NAS already mounted at `/Volumes/DSMedia`
2. **Create Mount Point**: Creates directory if needed
3. **Mount SMB Share**:
   - Attempts GUI mount via `open smb://...`
   - Falls back to command-line mount if GUI fails
4. **Verify Access**: Tests read access to mounted directory

### Phase 3: Docker Network Setup

1. **Network Creation**: Creates or verifies Docker network exists
2. **Network Naming**: Uses `${HOSTNAME_LOWER}-network` pattern

### Phase 4: Configuration Migration

1. **Migration Check**: Looks for existing config at `~/plex-migration/`
2. **Backup Creation**: Backs up any existing Docker config
3. **File Copy**: Copies migration files to Docker config directory
4. **Ownership Setup**: Sets proper file ownership for container access

### Phase 5: Container Deployment

1. **Container Check**: Verifies if container already exists
2. **Container Creation**: Deploys new container with LinuxServer.io image
3. **Configuration**: Sets environment variables, volume mounts, port mappings
4. **Startup**: Starts container with restart policy

### Phase 6: Auto-Start Configuration

1. **Launch Agent Creation**: Creates plist for operator user
2. **Permission Setup**: Configures proper ownership
3. **Service Loading**: Attempts to load launch agent

### Phase 7: Verification

1. **Container Status**: Verifies container is running
2. **Service Access**: Provides access URLs
3. **Final Instructions**: Displays post-setup guidance

## Docker Container Configuration

### Environment Variables

- `TZ=${PLEX_TIMEZONE}`: Timezone setting
- `PUID=$(id -u)`: User ID for file permissions  
- `PGID=$(id -g)`: Group ID for file permissions
- `HOSTNAME=${HOSTNAME}-PLEX`: Container hostname
- `PLEX_CLAIM=${PLEX_CLAIM_TOKEN}`: Initial server claim (optional)

### Volume Mounts

- `${PLEX_CONFIG_DIR}:/config`: Plex configuration and database
- `${PLEX_MEDIA_MOUNT}:/media`: NAS media files (read-only recommended)

### Port Mappings

- `32400:32400/tcp`: Main Plex web interface
- `3005:3005/tcp`: Plex Home Theater via Plex Companion
- `8324:8324/tcp`: Roku via Plex Companion
- `32469:32469/tcp`: Plex DLNA Server
- `1900:1900/udp`: Plex DLNA Server
- `32410:32410/udp`: GDM network discovery
- `32412:32412/udp`: GDM network discovery  
- `32413:32413/udp`: GDM network discovery
- `32414:32414/udp`: GDM network discovery

### Restart Policy

- `--restart=unless-stopped`: Automatic restart except when manually stopped

## Auto-Start Configuration

### Launch Agent Details

**File**: `/Users/${OPERATOR_USERNAME}/Library/LaunchAgents/local.plex.docker.plist`

**Purpose**: Automatically starts Plex container when operator user logs in

**Behavior**:

- Triggers on user login (`RunAtLoad: true`)
- Does not keep alive (`KeepAlive: false`)
- Logs to `${OPERATOR_HOME}/.local/state/plex-autostart.log`

**Command Executed**: `/usr/local/bin/docker start ${PLEX_CONTAINER_NAME}`

### Manual Launch Agent Management

```bash
# Load launch agent (as operator user)
launchctl load ~/Library/LaunchAgents/local.plex.docker.plist

# Unload launch agent
launchctl unload ~/Library/LaunchAgents/local.plex.docker.plist

# Check launch agent status
launchctl list | grep local.plex.docker
```

## Logging

### Script Execution Log

**Location**: `~/.local/state/${HOSTNAME_LOWER}-apps.log`

**Content**: All script operations with timestamps

**Format**:

```plaintext
[YYYY-MM-DD HH:MM:SS] ====== Section Name ======
[YYYY-MM-DD HH:MM:SS] Operation description
[YYYY-MM-DD HH:MM:SS] ✅ Success message
[YYYY-MM-DD HH:MM:SS] ❌ Error message
```

### Auto-Start Log

**Location**: `/Users/${OPERATOR_USERNAME}/.local/state/plex-autostart.log`

**Content**: Launch agent execution output

### Container Logs

```bash
# View Plex container logs
docker logs ${HOSTNAME_LOWER}-plex

# Follow logs in real-time
docker logs -f ${HOSTNAME_LOWER}-plex
```

## Troubleshooting

### Common Issues

#### 1. Docker Not Running

**Symptoms**: Script exits with "Docker is not running" message

**Solutions**:

- Start Docker Desktop application
- Verify Docker daemon is running: `docker info`
- Check Docker Desktop is signed in and licensed

#### 2. NAS Mount Failures

**Symptoms**:

- "Mount verification failed" message
- Cannot access media files

**Solutions**:

```bash
# Check current mounts
mount | grep DSMedia

# Manual SMB mount
sudo mount -t smbfs smb://plex@pecorino.local/DSMedia /Volumes/DSMedia

# Test NAS connectivity
ping pecorino.local

# Check SMB service on NAS
telnet pecorino.local 445
```

**Credential Issues**:

- Verify NAS user `plex` exists and has access to `DSMedia` share
- Try mounting with different credentials
- Check NAS SMB/CIFS service is running

#### 3. Configuration Migration Failures

**Symptoms**:

- Migration files not found
- Permission errors during copy

**Solutions**:

```bash
# Verify migration files exist
ls -la ~/plex-migration/

# Check permissions
ls -la "~/plex-migration/Plex Media Server/"

# Manual permission fix
chown -R $(id -u):$(id -g) "~/plex-migration/"

# Manual migration
cp -R "~/plex-migration/Plex Media Server"/* "~/Docker/plex/config/"
```

#### 4. Container Creation Failures

**Symptoms**: Docker container fails to start

**Debugging**:

```bash
# Check container status
docker ps -a | grep plex

# View container logs
docker logs ${HOSTNAME_LOWER}-plex

# Try manual container creation
docker run -it --rm lscr.io/linuxserver/plex:latest /bin/bash
```

**Common Causes**:

- Port conflicts (another service using port 32400)
- Volume mount issues (path doesn't exist or no permissions)
- Network conflicts

#### 5. Auto-Start Not Working

**Symptoms**: Plex doesn't start when operator logs in

**Debugging**:

```bash
# Check launch agent exists
ls -la /Users/${OPERATOR_USERNAME}/Library/LaunchAgents/local.plex.docker.plist

# Check launch agent status (as operator user)
launchctl list | grep local.plex.docker

# View auto-start logs
cat /Users/${OPERATOR_USERNAME}/.local/state/plex-autostart.log

# Manually load launch agent
sudo -u ${OPERATOR_USERNAME} launchctl load /Users/${OPERATOR_USERNAME}/Library/LaunchAgents/local.plex.docker.plist
```

#### 6. Network Access Issues

**Symptoms**: Cannot access Plex web interface

**Solutions**:

```bash
# Check if Plex is listening
netstat -an | grep 32400

# Test local access
curl -I http://localhost:32400/web

# Check firewall settings
sudo pfctl -sr | grep 32400

# Verify container networking
docker network inspect ${HOSTNAME_LOWER}-network
```

### Advanced Troubleshooting

#### Reset Plex Configuration

```bash
# Stop and remove container
docker stop ${HOSTNAME_LOWER}-plex
docker rm ${HOSTNAME_LOWER}-plex

# Backup and clear config
mv ~/Docker/plex/config ~/Docker/plex/config.backup.$(date +%Y%m%d)
mkdir -p ~/Docker/plex/config

# Re-run setup script
./app-setup/plex-setup.sh --skip-migration
```

#### Clean Complete Reinstall

```bash
# Remove everything
docker stop ${HOSTNAME_LOWER}-plex
docker rm ${HOSTNAME_LOWER}-plex
rm -rf ~/Docker/plex/
sudo -u ${OPERATOR_USERNAME} launchctl unload /Users/${OPERATOR_USERNAME}/Library/LaunchAgents/local.plex.docker.plist
rm /Users/${OPERATOR_USERNAME}/Library/LaunchAgents/local.plex.docker.plist

# Unmount NAS
sudo umount /Volumes/DSMedia

# Re-run full setup
./app-setup/plex-setup.sh
```

#### Manual Container Creation

If the script fails, you can manually create the container:

```bash
docker run -d \
  --name=${HOSTNAME_LOWER}-plex \
  --network=${HOSTNAME_LOWER}-network \
  --restart=unless-stopped \
  -e TZ=America/Los_Angeles \
  -e PUID=$(id -u) \
  -e PGID=$(id -g) \
  -e HOSTNAME=${HOSTNAME}-PLEX \
  -p 32400:32400/tcp \
  -p 3005:3005/tcp \
  -p 8324:8324/tcp \
  -p 32469:32469/tcp \
  -p 1900:1900/udp \
  -p 32410:32410/udp \
  -p 32412:32412/udp \
  -p 32413:32413/udp \
  -p 32414:32414/udp \
  -v ~/Docker/plex/config:/config \
  -v /Volumes/DSMedia:/media \
  lscr.io/linuxserver/plex:latest
```

## Security Considerations

### File Permissions

- Plex config files owned by admin user
- Container runs with admin user's UID/GID
- NAS mount accessible to admin user

### Network Security

- Container attached to isolated Docker network
- Ports exposed only as needed for Plex functionality
- No SSH or shell access to container

### Credential Storage

- NAS credentials handled via macOS Keychain
- No plaintext passwords in scripts or logs
- Plex claim tokens are temporary (4-minute expiry)

## Performance Optimization

### Transcoding

- Hardware transcoding available with Plex Pass
- Transcoding occurs in container's `/tmp` (memory-backed)
- Consider mounting additional volume for transcoding if needed

### Media Access

- NAS connection via gigabit Ethernet recommended
- SMB3 protocol used for better performance
- Consider NFS if supported by NAS for better performance

### Container Resources

- No explicit resource limits set (uses host resources)
- Consider Docker resource constraints for shared systems

## Integration with Server Setup

### Configuration Inheritance

The script inherits configuration from the main server setup:

- Server naming conventions
- User account structure  
- Docker network topology
- Logging patterns

### Compatibility

- Designed to run after `first-boot.sh` completion
- Requires Docker Desktop to be installed
- Compatible with existing Docker networks and containers

### Future Applications

The script pattern can be adapted for other containerized applications:

- Similar configuration derivation
- Consistent logging and error handling
- Standard auto-start mechanisms
