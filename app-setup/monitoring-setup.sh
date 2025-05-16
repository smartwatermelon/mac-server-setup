#!/bin/bash
#
# monitoring-setup.sh - System monitoring setup script for Mac Mini M2 'TILSIT' server
#
# This script sets up system monitoring tools for the Mac Mini server,
# including automatic health checks and alert notifications.
#
# Usage: ./monitoring-setup.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude
# Version: 1.0
# Created: 2025-05-13

# Exit on error
set -e

# Configuration variables - adjust as needed
export LOG_DIR; LOG_DIR="$HOME/.local/state" # XDG_STATE_HOME
LOG_FILE="$LOG_DIR/tilsit-monitoring.log"
SCRIPTS_DIR="${HOME}/tilsit-scripts/monitoring"
HEALTHCHECK_INTERVAL=15  # Minutes between health checks
EMAIL_ALERTS="your.email@example.com"  # Change to your email

# Parse command line arguments
FORCE=false

for arg in "$@"; do
  case $arg in
    --force)
      FORCE=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Function to log messages to both console and log file
log() {
  mkdir -p "$LOG_DIR"
  local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $1"
  echo "[$timestamp] $1" | sudo tee -a "$LOG_FILE" >/dev/null
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Function to check if a command was successful
check_success() {
  if [ $? -eq 0 ]; then
    log "✅ $1"
  else
    log "❌ $1 failed"
    if [ "$FORCE" = false ]; then
      read -p "Continue anyway? (y/n) " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  sudo touch "$LOG_FILE"
  sudo chmod 644 "$LOG_FILE"
fi

# Print header
section "Setting Up System Monitoring"
log "Running as user: $(whoami)"
log "Date: $(date)"

# Confirm operation if not forced
if [ "$FORCE" = false ]; then
  read -p "This script will set up system monitoring tools for your Mac Mini server. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
  
  # Ask for email confirmation
  if [ "$EMAIL_ALERTS" = "your.email@example.com" ]; then
    read -rp "Enter email address for alerts: " USER_EMAIL
    if [ -n "$USER_EMAIL" ]; then
      EMAIL_ALERTS="$USER_EMAIL"
      log "Email set to: $EMAIL_ALERTS"
    else
      log "No email provided, using default: $EMAIL_ALERTS"
    fi
  fi
fi

# Create scripts directory
section "Creating Scripts Directory"
if [ ! -d "$SCRIPTS_DIR" ]; then
  log "Creating monitoring scripts directory: $SCRIPTS_DIR"
  mkdir -p "$SCRIPTS_DIR"
  check_success "Scripts directory creation"
else
  log "Monitoring scripts directory already exists"
fi

# Create health check script
section "Creating Health Check Script"
HEALTH_CHECK_SCRIPT="$SCRIPTS_DIR/health_check.sh"

if [ ! -f "$HEALTH_CHECK_SCRIPT" ]; then
  log "Creating health check script"
  cat > "$HEALTH_CHECK_SCRIPT" << EOF
#!/bin/bash
#
# health_check.sh - System health check script for Mac Mini M2 'TILSIT' server
#
# This script checks various system health parameters and sends alerts if needed
#
# Created: $(date +"%Y-%m-%d")

# Configuration
LOG_DIR="$HOME/.local/state" # XDG_STATE_HOME
LOG_FILE="$LOG_DIR/tilsit-monitoring.log"
EMAIL_ALERTS="$EMAIL_ALERTS"
HOSTNAME="\$(hostname)"
DISK_THRESHOLD=90  # Alert if disk usage exceeds this percentage
CPU_THRESHOLD=90   # Alert if CPU load exceeds this percentage over 5 min
MEM_THRESHOLD=90   # Alert if memory usage exceeds this percentage
MAX_TEMP=85        # Alert if temperature exceeds this value (°C)

# Log function
log() {
  local timestamp=\$(date +"%Y-%m-%d %H:%M:%S")
  echo "[\$timestamp] \$1" >> "\$LOG_FILE"
}

# Send email alert
send_alert() {
  local subject="🚨 TILSIT Server Alert: \$1"
  local message="\$2"
  
  echo "\$message" | mail -s "\$subject" "\$EMAIL_ALERTS"
  log "Alert sent: \$subject"
}

# Record start time
log "Starting health check on \$HOSTNAME"
START_TIME=\$(date +%s)

# Check disk usage
log "Checking disk usage"
DISK_USAGE=\$(df -h / | awk 'NR==2 {print \$5}' | sed 's/%//')

if [ "\$DISK_USAGE" -gt "\$DISK_THRESHOLD" ]; then
  ALERT_MSG="Disk usage on \$HOSTNAME is critical: \${DISK_USAGE}%"
  log "\$ALERT_MSG"
  send_alert "High Disk Usage" "\$ALERT_MSG"
else
  log "Disk usage normal: \${DISK_USAGE}%"
fi

# Check CPU load
log "Checking CPU load"
# Get 5-min load average and divide by number of cores to get percentage
NUM_CORES=\$(sysctl -n hw.ncpu)
LOAD_AVG=\$(sysctl -n vm.loadavg | awk '{print \$3}')
CPU_PERCENT=\$(echo "\$LOAD_AVG \$NUM_CORES" | awk '{printf "%.1f", \$1/\$2*100}')

if [ \$(echo "\$CPU_PERCENT > \$CPU_THRESHOLD" | bc -l) -eq 1 ]; then
  ALERT_MSG="CPU load on \$HOSTNAME is critical: \${CPU_PERCENT}%"
  log "\$ALERT_MSG"
  send_alert "High CPU Load" "\$ALERT_MSG"
else
  log "CPU load normal: \${CPU_PERCENT}%"
fi

# Check memory usage
log "Checking memory usage"
# Parse memory statistics
PAGE_SIZE=\$(vm_stat | grep "page size" | awk '{print \$8}')
FREE_PAGES=\$(vm_stat | grep "Pages free" | awk '{print \$3}' | sed 's/\.//')
ACTIVE_PAGES=\$(vm_stat | grep "Pages active" | awk '{print \$3}' | sed 's/\.//')
INACTIVE_PAGES=\$(vm_stat | grep "Pages inactive" | awk '{print \$3}' | sed 's/\.//')
SPECULATIVE_PAGES=\$(vm_stat | grep "Pages speculative" | awk '{print \$3}' | sed 's/\.//')
WIRED_PAGES=\$(vm_stat | grep "Pages wired down" | awk '{print \$4}' | sed 's/\.//')
COMPRESSED_PAGES=\$(vm_stat | grep "Pages occupied by compressor" | awk '{print \$5}' | sed 's/\.//')

# Calculate used and total memory
USED_MEM=\$(( (ACTIVE_PAGES + INACTIVE_PAGES + WIRED_PAGES + COMPRESSED_PAGES) * PAGE_SIZE / 1024 / 1024 ))
FREE_MEM=\$(( (FREE_PAGES + SPECULATIVE_PAGES) * PAGE_SIZE / 1024 / 1024 ))
TOTAL_MEM=\$(( USED_MEM + FREE_MEM ))
MEM_PERCENT=\$(( USED_MEM * 100 / TOTAL_MEM ))

if [ "\$MEM_PERCENT" -gt "\$MEM_THRESHOLD" ]; then
  ALERT_MSG="Memory usage on \$HOSTNAME is critical: \${MEM_PERCENT}%"
  log "\$ALERT_MSG"
  send_alert "High Memory Usage" "\$ALERT_MSG"
else
  log "Memory usage normal: \${MEM_PERCENT}%"
fi

# Check system temperature
log "Checking system temperature"
if command -v osx-cpu-temp &>/dev/null; then
  TEMP=\$(osx-cpu-temp | grep -oE '[0-9]+\.[0-9]+' | awk '{printf "%.0f", \$1}')
  
  if [ "\$TEMP" -gt "\$MAX_TEMP" ]; then
    ALERT_MSG="Temperature on \$HOSTNAME is critical: \${TEMP}°C"
    log "\$ALERT_MSG"
    send_alert "High Temperature" "\$ALERT_MSG"
  else
    log "Temperature normal: \${TEMP}°C"
  fi
else
  log "osx-cpu-temp not installed, skipping temperature check"
fi

# Check for Docker container status
if command -v docker &>/dev/null; then
  log "Checking Docker containers"
  
  # Get list of containers that should be running
  CONTAINERS=\$(docker ps -a --format '{{.Names}}' | grep -E 'plex|nginx|transmission')
  
  for CONTAINER in \$CONTAINERS; do
    if ! docker ps --format '{{.Names}}' | grep -q "\$CONTAINER"; then
      ALERT_MSG="Container \$CONTAINER is not running on \$HOSTNAME"
      log "\$ALERT_MSG"
      send_alert "Container Down" "\$ALERT_MSG"
    else
      log "Container \$CONTAINER is running"
    fi
  done
else
  log "Docker not installed, skipping container checks"
fi

# Check for system updates
log "Checking for system updates"
softwareupdate -l &> /tmp/updates_check

if grep -q "No new software available" /tmp/updates_check; then
  log "No system updates available"
else
  UPDATES=\$(grep -A 100 "Software Update found" /tmp/updates_check | grep -B 100 "You can install" | grep -v "You can install")
  log "System updates available: \$UPDATES"
  # We don't alert for updates, just log them
fi

rm -f /tmp/updates_check

# Record finish time and duration
END_TIME=\$(date +%s)
DURATION=\$(( END_TIME - START_TIME ))
log "Health check completed in \$DURATION seconds"

exit 0
EOF

  chmod +x "$HEALTH_CHECK_SCRIPT"
  check_success "Health check script creation"
else
  log "Health check script already exists"
fi

# Install required packages for monitoring
section "Installing Monitoring Tools"

if ! command -v bc &>/dev/null; then
  log "Installing bc calculator"
  brew install bc
  check_success "bc calculator installation"
else
  log "bc calculator already installed"
fi

if ! command -v osx-cpu-temp &>/dev/null; then
  log "Installing osx-cpu-temp"
  brew install osx-cpu-temp
  check_success "osx-cpu-temp installation"
else
  log "osx-cpu-temp already installed"
fi

# Set up cron job for health checks
section "Setting Up Scheduled Health Checks"
CRON_FILE=$(mktemp)

# Get existing crontab
crontab -l > "$CRON_FILE" 2>/dev/null || echo "# TILSIT health checks" > "$CRON_FILE"

# Check if our health check is already in crontab
if ! grep -q "health_check.sh" "$CRON_FILE"; then
  log "Adding health check to crontab"
  echo "# Run TILSIT health check every $HEALTHCHECK_INTERVAL minutes" >> "$CRON_FILE"
  echo "*/$HEALTHCHECK_INTERVAL * * * * $HEALTH_CHECK_SCRIPT" >> "$CRON_FILE"
  crontab "$CRON_FILE"
  check_success "Crontab update"
else
  log "Health check already in crontab"
fi

rm "$CRON_FILE"

# Create status script
section "Creating Status Script"
STATUS_SCRIPT="$SCRIPTS_DIR/server_status.sh"

if [ ! -f "$STATUS_SCRIPT" ]; then
  log "Creating server status script"
  cat > "$STATUS_SCRIPT" << 'EOF'
#!/bin/bash
#
# server_status.sh - Get status summary for Mac Mini M2 'TILSIT' server
#
# This script provides a summary of the server's current status
#
# Created: $(date +"%Y-%m-%d")

echo "====== TILSIT Server Status ======"
echo "Time: $(date)"
echo "Uptime: $(uptime)"
echo ""

echo "====== System Resources ======"
echo "CPU Load: $(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')"
echo "Memory Usage:"
vm_stat | grep -E "Pages (free|active|inactive|speculative|wired)" | awk '{ gsub(/\./,"",$NF); print $0 }'
echo ""
echo "Disk Usage:"
df -h / /Volumes/* 2>/dev/null | grep -v "/dev/loop"
echo ""

echo "====== Network Status ======"
echo "IP Address: $(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
echo "Network Interfaces:"
ifconfig -a | grep -E 'inet |status:' | grep -v '127.0.0.1'
echo ""

echo "====== Docker Containers ======"
if command -v docker &>/dev/null; then
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
else
  echo "Docker not installed"
fi
echo ""

echo "====== Running Services ======"
echo "SSH Status: $(sudo systemsetup -getremotelogin)"
sudo launchctl list | grep -v '^-' | head -n 20
echo "... (showing first 20 services only)"
echo ""

echo "====== Recent System Logs ======"
log show --predicate 'eventMessage contains "error" or eventMessage contains "fail"' --last 24h --style compact | tail -n 20
echo "... (showing last 20 error logs only)"
echo ""

echo "====== Recent Monitoring Alerts ======"
if [ -f "$LOG_DIR/tilsit-monitoring.log" ]; then
  grep "Alert sent" $LOG_DIR/tilsit-monitoring.log | tail -n 10
else
  echo "No monitoring log found"
fi
echo ""

echo "====== End of Status Report ======"
EOF

  chmod +x "$STATUS_SCRIPT"
  check_success "Status script creation"
else
  log "Status script already exists"
fi

# Create backup script
section "Creating Backup Script"
BACKUP_SCRIPT="$SCRIPTS_DIR/backup.sh"

if [ ! -f "$BACKUP_SCRIPT" ]; then
  log "Creating backup script"
  cat > "$BACKUP_SCRIPT" << 'EOF'
#!/bin/bash
#
# backup.sh - Backup script for Mac Mini M2 'TILSIT' server
#
# This script creates backups of important configuration files and data
#
# Usage: ./backup.sh [destination_directory]
#   destination_directory: Where to store the backup (default: ~/Backups)
#
# Created: $(date +"%Y-%m-%d")

# Configuration
LOG_DIR="$HOME/.local/state" # XDG_STATE_HOME
LOG_FILE="$LOG_DIR/tilsit-monitoring.log"
DEFAULT_BACKUP_DIR="${HOME}/Backups"
BACKUP_DIR="${1:-$DEFAULT_BACKUP_DIR}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="tilsit-backup-${TIMESTAMP}.tar.gz"

# Log function
log() {
  mkdir -p "$LOG_DIR"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $1"
  echo "[$timestamp] $1" >> "$LOG_FILE"
}

# Print header
log "Starting TILSIT backup to $BACKUP_DIR/$BACKUP_FILE"

# Create backup directory if it doesn't exist
if [ ! -d "$BACKUP_DIR" ]; then
  mkdir -p "$BACKUP_DIR"
  if [ $? -ne 0 ]; then
    log "Failed to create backup directory: $BACKUP_DIR"
    exit 1
  fi
  log "Created backup directory: $BACKUP_DIR"
fi

# Create temporary directory for backup files
TEMP_DIR=$(mktemp -d)
log "Created temporary directory: $TEMP_DIR"

# Create directories for backup structure
mkdir -p "$TEMP_DIR/docker-config"
mkdir -p "$TEMP_DIR/scripts"
mkdir -p "$TEMP_DIR/system-config"

# Copy Docker configuration files
log "Backing up Docker configuration files"
cp -R "${HOME}/Docker" "$TEMP_DIR/docker-config/" 2>/dev/null || log "No Docker config found"

# Copy scripts
log "Backing up scripts"
cp -R "${HOME}/tilsit-scripts" "$TEMP_DIR/scripts/" 2>/dev/null || log "No scripts found"

# Copy system configuration files
log "Backing up system configuration files"
cp /etc/hosts "$TEMP_DIR/system-config/" 2>/dev/null || log "Failed to backup /etc/hosts"
cp /etc/ssh/sshd_config "$TEMP_DIR/system-config/" 2>/dev/null || log "Failed to backup sshd_config"
cp "${HOME}/.bash_profile" "$TEMP_DIR/system-config/" 2>/dev/null || log "No bash_profile found"
cp "${HOME}/.zprofile" "$TEMP_DIR/system-config/" 2>/dev/null || log "No zprofile found"

# Backup crontab
crontab -l > "$TEMP_DIR/system-config/crontab" 2>/dev/null || log "No crontab found"

# Backup brew packages list
if command -v brew &>/dev/null; then
  log "Backing up Homebrew package lists"
  brew list --formula > "$TEMP_DIR/system-config/brew-formulae.txt"
  brew list --cask > "$TEMP_DIR/system-config/brew-casks.txt"
else
  log "Homebrew not installed, skipping package list backup"
fi

# Create the backup archive
log "Creating backup archive"
tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C "$TEMP_DIR" .
if [ $? -eq 0 ]; then
  log "Backup created successfully: $BACKUP_DIR/$BACKUP_FILE"
else
  log "Failed to create backup archive"
  rm -rf "$TEMP_DIR"
  exit 1
fi

# Calculate backup size
BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_FILE" | cut -f1)
log "Backup size: $BACKUP_SIZE"

# Clean up temporary directory
rm -rf "$TEMP_DIR"
log "Cleaned up temporary directory"

log "Backup completed successfully"

# Print backup information
echo "====== TILSIT Backup Complete ======"
echo "Backup file: $BACKUP_DIR/$BACKUP_FILE"
echo "Backup size: $BACKUP_SIZE"
echo "Date: $(date)"
echo "======================================="

exit 0
EOF

  chmod +x "$BACKUP_SCRIPT"
  check_success "Backup script creation"
else
  log "Backup script already exists"
fi

# Test health check script
section "Testing Health Check Script"
log "Running health check script for testing"
"$HEALTH_CHECK_SCRIPT" || log "Health check script test completed with errors"

# Provide instructions
section "Monitoring Setup Complete"
log "System monitoring has been set up successfully"
log "Health checks will run every $HEALTHCHECK_INTERVAL minutes"
log "Alerts will be sent to: $EMAIL_ALERTS"

log "Additional monitoring scripts created:"
log "- Server status script: $STATUS_SCRIPT"
log "- Backup script: $BACKUP_SCRIPT"

log "You can run these scripts manually at any time"

exit 0
