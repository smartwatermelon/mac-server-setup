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
- **Default behavior**: Interactive prompts with sensible defaults (Y/n for proceed, y/N for destructive actions)
- `--skip-migration`: Skip Plex configuration migration
- `--skip-mount`: Skip SMB mount setup
- `--server-name NAME`: Set Plex server name (default: hostname)
- `--migrate-from HOST`: Source hostname for Plex migration (e.g., old-server.local)

**Examples**:

```bash
# Full interactive setup with migration
./app-setup/plex-setup.sh

# Unattended fresh installation
./app-setup/plex-setup.sh --force --skip-migration

# Setup without NAS mounting (mount manually later)
./app-setup/plex-setup.sh --skip-mount

# Setup with custom server name
./app-setup/plex-setup.sh --server-name "MyPlexServer"

# Setup with automated migration from existing server
./app-setup/plex-setup.sh --migrate-from old-server.local
```

## Configuration Sources

The script derives its configuration from multiple sources in the following priority order:

### 1. Server Configuration File

**Source**: `config.conf` (in same directory as script)

**Key Variables Used**:

- `SERVER_NAME`: Primary server identifier
- `OPERATOR_USERNAME`: Non-admin user account name
- `NAS_HOSTNAME`: NAS hostname for SMB connection
- `NAS_USERNAME`: Username for NAS access
- `NAS_SHARE_NAME`: Name of the media share on NAS
- `PLEX_MIGRATE_FROM`: Source hostname for Plex migration (optional)
- `HOSTNAME_OVERRIDE`: Custom hostname (optional)
- `DOCKER_NETWORK_OVERRIDE`: Custom Docker network name (optional)

**Derived Variables**:

```bash
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
DOCKER_NETWORK="${DOCKER_NETWORK_OVERRIDE:-${HOSTNAME_LOWER}-network}"
```

### 2. Derived Script Configuration

**NAS Configuration**:

- `NAS_SMB_URL="smb://${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME}"`
- `PLEX_MEDIA_MOUNT="/Volumes/${NAS_SHARE_NAME}"`

**Docker Configuration**:

- `PLEX_CONTAINER_NAME="${HOSTNAME_LOWER}-plex"`
- Docker image: `lscr.io/linuxserver/plex:latest`
- Timezone: Auto-detected from system (`readlink /etc/localtime`)
- Server name: `${PLEX_SERVER_NAME}` (--server-name option or hostname)

**Directory Paths**:

- `PLEX_CONFIG_DIR="${HOME}/Docker/plex/config"`
- `PLEX_MIGRATION_DIR="${HOME}/plex-migration"`
- `LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-apps.log"`

### 3. Runtime Configuration

**User Input** (when not using `--force`):

- Plex claim token (for fresh installations)
- Confirmation prompts for each major operation (most default to Yes - just press Enter)
- NAS mounting credentials (via macOS GUI when 1Password unavailable)

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
│   ├── Cache/                  # Will be excluded during migration
│   └── ... (all other subdirectories)
└── com.plexapp.plexmediaserver.plist   # macOS preferences file
```

**Migration follows official Plex guidelines**: This process is based on Plex's official documentation:

- [Move an Install to Another System](https://support.plex.tv/articles/201370363-move-an-install-to-another-system/)
- [Where is the Plex Media Server Data Directory Located](https://support.plex.tv/articles/202915258-where-is-the-plex-media-server-data-directory-located/)

**How to Obtain These Files** (following [Plex's migration guide](https://support.plex.tv/articles/201370363-move-an-install-to-another-system/)):

1. **Preparation on Source Server**:
   - Disable "Empty trash automatically after every scan" in Plex settings
   - Stop Plex Media Server completely

2. **From macOS Plex Server** (recommended method):

   ```bash
   # On the old server, copy main directory excluding Cache (recommended by Plex)
   rsync -av --exclude='Cache' "~/Library/Application Support/Plex Media Server/" ~/migration-backup/
   
   # Copy the macOS preferences file
   cp "~/Library/Preferences/com.plexapp.plexmediaserver.plist" ~/migration-backup/
   
   # Transfer to new server at ~/plex-migration/
   ```

3. **Alternative Method** (if rsync unavailable, but slower):

   ```bash
   # Copy complete directory (includes Cache - will be handled during migration)
   cp -R "~/Library/Application Support/Plex Media Server" ~/migration-backup/
   cp "~/Library/Preferences/com.plexapp.plexmediaserver.plist" ~/migration-backup/
   ```

**Important**: The Cache directory can be large and is not needed for migration. The setup script will automatically exclude it during the migration process using rsync when available.

### Generated Directory Structure

After script execution:

```plaintext
~/Docker/plex/
└── config/                     # Plex configuration (mapped to container)
    ├── Library/                # Plex application data
    ├── Logs/                   # Plex logs
    └── ... (Plex directory structure)

# No LaunchAgents needed - auto-start handled by Docker restart policy

~/.local/state/
└── ${HOSTNAME_LOWER}-apps.log  # Script execution log
```

## Operation Flow

### Phase 1: Initialization

1. **Load Configuration**: Sources `config.conf` from script directory and derives variables
2. **Parse Arguments**: Processes command-line flags
3. **Validate Prerequisites**: Checks Docker availability
4. **User Confirmation**: Prompts for operation confirmation with sensible defaults (unless `--force`):
   - Setup operations default to **Yes** - press Enter to continue
   - Destructive operations default to **No** - requires explicit confirmation

### Phase 2: NAS Mount Setup

1. **Check Existing Mount**: Verifies if NAS already mounted at `/Volumes/${NAS_SHARE_NAME}`
2. **Create Mount Point**: Creates directory with proper ownership if needed
3. **Mount SMB Share**:
   - Uses 1Password credentials if available (with URL encoding for special characters)
   - Falls back to interactive mount prompt if 1Password fails
   - Utilizes `mount_smbfs` with proper permission flags (`-f 0777 -d 0777`)
   - Converts usernames to lowercase for SMB compatibility
4. **Verify Access**: Tests read access to mounted directory with detailed debugging
5. **Configure autofs**: Sets up macOS native autofs for automatic mounting on boot

### Phase 3: Docker Network Setup

1. **Network Creation**: Creates or verifies Docker network exists
2. **Network Naming**: Uses `${HOSTNAME_LOWER}-network` pattern

### Phase 4: Configuration Migration

**Automated Migration** (new in v2.0):

1. **Source Detection**: Checks for migration source from config file or command line
2. **Interactive Discovery**: Scans network for existing Plex servers using `dns-sd` with clean server list display
3. **SSH Connectivity**: Tests SSH connection to source server
4. **Size Estimation**: Provides migration size estimates (total size, files, directories)
5. **Automated Transfer**: Uses `rsync` with progress indication to transfer config
6. **Plist Handling**: Copies macOS preferences file for reference

**Local Migration** (existing):

1. **Migration Check**: Looks for existing config at `~/plex-migration/`
2. **Backup Creation**: Backs up any existing Docker config with timestamp
3. **Smart File Copy** (following [Plex best practices](https://support.plex.tv/articles/201370363-move-an-install-to-another-system/)):
   - Uses `rsync --exclude='Cache'` when available (recommended by Plex)
   - Falls back to `cp` with Cache directory warning if rsync unavailable
   - Preserves all settings, libraries, and metadata
4. **macOS Preferences Handling**:
   - Detects and acknowledges `com.plexapp.plexmediaserver.plist`
   - Notes that plist preferences don't apply to Docker containers
   - Container uses environment variables instead
5. **Ownership Setup**: Sets proper file ownership for container access
6. **Post-Migration Guidance**: Provides specific steps for completing the migration

### Phase 5: Container Deployment

1. **Container Check**: Verifies if container already exists
2. **Container Creation**: Deploys new container with LinuxServer.io image
3. **Configuration**: Sets environment variables, volume mounts, port mappings
4. **Startup**: Starts container with restart policy

### Phase 6: Auto-Start Configuration

1. **Docker Restart Policy**: Container configured with --restart=unless-stopped
2. **Colima Integration**: When Colima starts via brew services, Docker starts
3. **Automatic Container Start**: Docker automatically starts containers with restart policy

### Phase 7: Verification

1. **Container Status**: Verifies container is running
2. **Service Access**: Provides access URLs
3. **Final Instructions**: Displays post-setup guidance

## Docker Container Configuration

### Environment Variables

- `TZ=${PLEX_TIMEZONE}`: Timezone setting
- `PUID=$(id -u)`: User ID for file permissions  
- `PGID=$(id -g)`: Group ID for file permissions
- `HOSTNAME=${PLEX_SERVER_NAME}`: Container hostname (customizable via --server-name)
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

### Docker Restart Policy

**Method**: Docker's built-in `--restart=unless-stopped` policy

**Purpose**: Automatically starts Plex container when Docker daemon starts

**Behavior**:

- Starts when Docker daemon starts (via Colima)
- Restarts if container crashes
- Does not restart if manually stopped
- No additional configuration needed

**Integration with Colima**:

- Colima starts automatically via `brew services` when operator logs in
- Docker daemon starts with Colima
- Containers with restart policy start automatically

### Automatic NAS Mounting with autofs

**Method**: macOS native autofs subsystem

**Purpose**: Automatically mount NAS share when accessed, survives reboots

**Configuration Files**:

- `/etc/auto_master`: Main autofs configuration
- `/etc/auto_smb`: SMB share definitions

**Setup Process**:

1. **autofs Master Configuration**: Adds `/-  auto_smb  -nosuid,noowners` to `/etc/auto_master`
2. **SMB Configuration**: Creates `/etc/auto_smb` with mount definition:

   ```bash
   /Volumes/DSMedia  -fstype=smbfs,soft,noowners,nosuid,rw ://username:password@hostname/share
   ```

3. **Service Restart**: Reloads autofs configuration with `automount -cv`
4. **Credential Handling**:
   - Uses 1Password credentials when available
   - URL-encodes passwords to handle special characters (e.g., @ symbols)
   - Falls back to interactive prompts if credentials unavailable

**Behavior**:

- Mount triggered automatically when directory is accessed
- Unmounts automatically after period of inactivity
- Survives system reboots and network reconnections
- No manual mounting required

**Benefits over LaunchAgents**:

- Uses built-in macOS functionality
- More reliable than custom scripts
- Better network handling and reconnection
- Lower system overhead

**Limitations**:

- Configuration may be reset during major macOS system updates
- Requires re-running setup after system upgrades if mounting fails

### Manual Container Management

```bash
# Start container manually
docker start ${HOSTNAME_LOWER}-plex

# Stop container (will not restart until manually started or Docker restarts)
docker stop ${HOSTNAME_LOWER}-plex

# Check container status
docker ps -a | grep plex
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

## Migration Best Practices

### Following Official Plex Guidelines

The migration process implements recommendations from Plex's official documentation:

- **[Move an Install to Another System](https://support.plex.tv/articles/201370363-move-an-install-to-another-system/)**: Complete migration workflow
- **[Where is the Plex Media Server Data Directory Located](https://support.plex.tv/articles/202915258-where-is-the-plex-media-server-data-directory-located/)**: Source directory locations

### Migration Process Details

1. **Cache Directory Handling**:
   - Automatically excluded using `rsync --exclude='Cache'` (Plex recommendation)
   - Fallback to `cp` with warning if rsync unavailable
   - Cache rebuilds automatically and safely after migration

2. **macOS Preferences (plist) File**:
   - Detected and preserved for reference
   - Not directly usable in Docker environment
   - Container uses environment variables instead
   - Original settings may need manual reconfiguration

3. **Post-Migration Requirements**:
   - Library paths must be updated from old paths to `/media/` container paths
   - Library scanning required to re-associate media files
   - All libraries should be verified for proper operation

### Expected Migration Timeline

- **Small libraries** (< 1000 items): 5-15 minutes
- **Medium libraries** (1000-10000 items): 15-60 minutes  
- **Large libraries** (> 10000 items): 1+ hours

  *Time depends on library size, metadata complexity, and system performance*

## Troubleshooting

### Common Issues

#### 1. Docker Not Running

**Symptoms**: Script exits with "Docker is not running" message

**Solutions**:

- **Using Colima (recommended for servers)**:

  ```bash
  colima start
  ```

- **Using Docker Desktop**:
  - Start Docker Desktop application
  - Check Docker Desktop is signed in and licensed
- **Verify Docker daemon is running**: `docker info`
- **Check status**: `colima status` (if using Colima)

#### 2. NAS Mount Failures

**Symptoms**:

- "Mount verification failed" message
- Cannot access media files
- Exit code 68 (authentication failure)

**Solutions**:

```bash
# Check current mounts
mount | grep ${NAS_SHARE_NAME}

# Manual SMB mount with proper syntax (adjust values per your config.conf)
sudo mkdir -p /Volumes/${NAS_SHARE_NAME}
sudo chown $(whoami):staff /Volumes/${NAS_SHARE_NAME}
mount_smbfs -f 0777 -d 0777 //${NAS_USERNAME}@${NAS_HOSTNAME}/${NAS_SHARE_NAME} /Volumes/${NAS_SHARE_NAME}

# Test NAS connectivity
ping ${NAS_HOSTNAME}

# Check SMB service on NAS
telnet ${NAS_HOSTNAME} 445

# Check autofs configuration
sudo cat /etc/auto_master | grep auto_smb
sudo cat /etc/auto_smb

# Restart autofs if needed
sudo automount -cv
```

**Common Mount Issues**:

- **Authentication failure (exit code 68)**:
  - Username case sensitivity (try lowercase username)
  - Password contains special characters (@ symbols need URL encoding)
  - Incorrect credentials in 1Password
- **Permission denied after successful mount**:
  - Mount point ownership incorrect
  - Missing permission flags in mount command
- **autofs configuration reset**:
  - macOS system update may have reset `/etc/auto_master`
  - Re-run `plex-setup.sh` to reconfigure autofs

**Credential Issues**:

- Verify NAS user exists and has access to media share (check config.conf values)
- Check 1Password item for correct username/password format
- Username should typically be lowercase for SMB compatibility
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
# Check if Colima is running
colima status

# Check if Docker is running
docker info

# Check container status and restart policy
docker inspect ${HOSTNAME_LOWER}-plex | grep -A5 RestartPolicy

# Check Colima auto-start service
brew services list | grep colima

# Manually start Colima if needed
colima start
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

# Stop Colima auto-start if needed
brew services stop colima

# Unmount NAS
sudo umount /Volumes/${NAS_SHARE_NAME}

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
  -v /Volumes/${NAS_SHARE_NAME}:/media \
  lscr.io/linuxserver/plex:latest
```

#### Interactive Prompts

**Default Behavior**: The script uses sensible defaults for all confirmation prompts:

- **Setup Operations** (Y/n): Default to Yes - press Enter to proceed
  - Continue with Plex setup
  - Start Colima/Docker
  - Mount NAS share
  - Use existing configurations
  - Apply migrations

- **Safety Prompts** (y/N): Default to No - requires explicit 'y' + Enter
  - Continue without NAS mount (after mount failure)
  - Get Plex claim token (optional step)

**Unattended Operation**: Use `--force` flag to automatically accept all defaults and skip prompts entirely.

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
- Requires Docker daemon (Colima recommended, Docker Desktop also supported)
- Compatible with existing Docker networks and containers
- Colima auto-starts when operator user logs in (if configured during setup)

### Future Applications

The script pattern can be adapted for other containerized applications:

- Similar configuration derivation
- Consistent logging and error handling
- Standard auto-start mechanisms
