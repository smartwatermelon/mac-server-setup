#!/usr/bin/env bash
#
# setup-vpn-killswitch.sh - PF kill-switch + _transmission system user setup
#
# This script implements Stage 4 of the VPN kill-switch plan:
# 1. Creates _transmission system account (daemon user, no login)
# 2. Creates data directories under /var/lib/transmission
# 3. Deploys PF anchor rules to /etc/pf.anchors/
# 4. Adds anchor reference to /etc/pf.conf
# 5. Creates LaunchDaemon to load PF rules at boot
# 6. Creates LaunchDaemon for transmission-daemon
# 7. Creates system-level NAS mount LaunchDaemon
#
# PREREQUISITES:
# - Stage 3 (pf-test-user.sh) must have PASSED
# - Stages 1-2 must be stable and proven
# - Transmission must be installed via Homebrew
# - Must be run as administrator (sudo access required)
#
# Usage: ./setup-vpn-killswitch.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-12

set -euo pipefail

# Parse arguments
FORCE=false
for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "Unknown option: ${arg}"
      echo "Usage: $0 [--force]"
      exit 1
      ;;
  esac
done

# Load common configuration
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
  NAS_HOSTNAME="${NAS_HOSTNAME:-nas.local}"
  NAS_USERNAME="${NAS_USERNAME:-plex}"
  NAS_SHARE_NAME="${NAS_SHARE_NAME:-DSMedia}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Error: SERVER_NAME not set in ${CONFIG_FILE}"
  exit 1
fi
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"

# Logging
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"
mkdir -p "${LOG_DIR}"

log() {
  mkdir -p "${LOG_DIR}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] $1" | tee -a "${LOG_FILE}"
}

show_log() {
  echo "$1"
  log "$1"
}

section() {
  log ""
  log "====== $1 ======"
}

CURRENT_SCRIPT_SECTION="Setup"

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "${CURRENT_SCRIPT_SECTION}"
}

log_error() {
  local message="$1"
  show_log "ERROR: [${CURRENT_SCRIPT_SECTION}] ${message}"
}

# Confirmation helper
confirm() {
  local prompt="$1"
  local default="${2:-y}"

  if [[ "${FORCE}" == "true" ]]; then
    if [[ "${default}" == "y" ]]; then return 0; else return 1; fi
  fi

  if [[ "${default}" == "y" ]]; then
    read -rp "${prompt} (Y/n): " -n 1 response
    echo
    response=${response:-y}
  else
    read -rp "${prompt} (y/N): " -n 1 response
    echo
    response=${response:-n}
  fi

  case "${response}" in
    [yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================================
# STAGE 4a: Create _transmission system account
# ============================================================================

create_transmission_user() {
  set_section "Creating _transmission System Account"

  # Check if user already exists
  if dscl . -read /Users/_transmission RecordName >/dev/null 2>&1; then
    log "User _transmission already exists"
    local existing_uid
    existing_uid=$(dscl . -read /Users/_transmission UniqueID | awk '{print $2}')
    log "  Existing UID: ${existing_uid}"
    return 0
  fi

  # Find unused UID/GID in daemon range (200-400)
  # Must check both users and groups to ensure the ID is free in both namespaces
  log "Finding unused UID/GID in daemon range (200-400)..."

  # Verify directory service is responding before trusting UID/GID lookups
  local user_list group_list
  user_list=$(dscl . -list /Users UniqueID 2>/dev/null) || {
    log_error "Cannot query directory service for users — dscl failed"
    return 1
  }
  group_list=$(dscl . -list /Groups PrimaryGroupID 2>/dev/null) || {
    log_error "Cannot query directory service for groups — dscl failed"
    return 1
  }

  local uid=250
  while echo "${user_list}" | awk -v u="${uid}" '$2 == u {found=1} END {exit !found}' \
    || echo "${group_list}" | awk -v g="${uid}" '$2 == g {found=1} END {exit !found}'; do
    ((uid += 1))
    if [[ ${uid} -gt 400 ]]; then
      log_error "No available UID/GID in range 200-400"
      return 1
    fi
  done

  log "Using UID/GID: ${uid}"

  # Create user
  sudo -p "[VPN Kill-Switch] Enter password to create _transmission user: " \
    dscl . -create /Users/_transmission
  sudo dscl . -create /Users/_transmission UserShell /usr/bin/false
  sudo dscl . -create /Users/_transmission RealName "Transmission Daemon"
  sudo dscl . -create /Users/_transmission UniqueID "${uid}"
  sudo dscl . -create /Users/_transmission PrimaryGroupID "${uid}"
  sudo dscl . -create /Users/_transmission NFSHomeDirectory /var/lib/transmission
  sudo dscl . -create /Users/_transmission Password "*"
  sudo dscl . -create /Users/_transmission IsHidden 1

  # Create group (if not already existing)
  if ! dscl . -read /Groups/_transmission RecordName >/dev/null 2>&1; then
    sudo dscl . -create /Groups/_transmission
    sudo dscl . -create /Groups/_transmission PrimaryGroupID "${uid}"
  else
    log "Group _transmission already exists"
  fi

  show_log "Created _transmission user (UID ${uid})"
}

# ============================================================================
# STAGE 4a (continued): Create data directories
# ============================================================================

create_data_directories() {
  set_section "Creating Data Directories"

  local dirs=(
    "/var/lib/transmission"
    "/var/lib/transmission/.config/transmission-daemon"
    "/var/lib/transmission/.filebot"
    "/var/lib/transmission/mnt"
    "/var/lib/transmission/Downloads"
  )

  for dir in "${dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then
      sudo -p "[VPN Kill-Switch] Enter password to create ${dir}: " \
        mkdir -p "${dir}"
      log "Created: ${dir}"
    else
      log "Exists: ${dir}"
    fi
  done

  sudo -p "[VPN Kill-Switch] Enter password to set ownership on /var/lib/transmission: " \
    chown -R _transmission:_transmission /var/lib/transmission

  # Grant _transmission read access to operator's watch directory (for .torrent file pickup)
  # operator's home is 700 by default, so we need ACLs on the path components
  local watch_dir="${OPERATOR_HOME}/.local/sync/dropbox"
  if [[ -d "${OPERATOR_HOME}" ]]; then
    log "Setting ACLs for _transmission to traverse ${watch_dir}..."
    sudo chmod +a "_transmission allow read,execute,search" "${OPERATOR_HOME}" 2>/dev/null || log "WARNING: Failed to set ACL on ${OPERATOR_HOME}"
    sudo chmod +a "_transmission allow read,execute,search" "${OPERATOR_HOME}/.local" 2>/dev/null || log "WARNING: Failed to set ACL on ${OPERATOR_HOME}/.local"
    sudo chmod +a "_transmission allow read,execute,search" "${OPERATOR_HOME}/.local/sync" 2>/dev/null || log "WARNING: Failed to set ACL on ${OPERATOR_HOME}/.local/sync"
    if [[ -d "${watch_dir}" ]]; then
      sudo chmod +a "_transmission allow read,execute,search,list" "${watch_dir}" 2>/dev/null || log "WARNING: Failed to set ACL on ${watch_dir}"
      log "ACLs set on watch directory path"
    else
      log "Watch directory ${watch_dir} does not exist yet (will be created by rclone setup)"
    fi
  fi

  show_log "Data directories created and owned by _transmission"
}

# ============================================================================
# STAGE 4b: NAS mount LaunchDaemon for _transmission
# ============================================================================

create_nas_mount_daemon() {
  set_section "Creating NAS Mount LaunchDaemon"

  local plist_path="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.mount-nas-transmission.plist"
  local mount_script="/var/lib/transmission/mount-nas.sh"

  # Create mount script for _transmission
  log "Creating NAS mount script at ${mount_script}..."

  sudo -p "[VPN Kill-Switch] Enter password to create NAS mount script: " \
    tee "${mount_script}" >/dev/null <<MOUNT_EOF
#!/usr/bin/env bash
# mount-nas.sh - Mount NAS share for _transmission daemon
# Runs at boot before transmission-daemon starts
set -euo pipefail

NAS_HOSTNAME="${NAS_HOSTNAME}"
NAS_SHARE_NAME="${NAS_SHARE_NAME}"
MOUNT_POINT="/var/lib/transmission/mnt/${NAS_SHARE_NAME}"
LOG_FILE="/var/lib/transmission/${HOSTNAME_LOWER}-mount.log"

log() {
  local timestamp
  timestamp=\$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [mount-nas-transmission] %s\n' "\${timestamp}" "\$1" | tee -a "\${LOG_FILE}"
}

# Wait for network
wait_for_network() {
  local max_attempts=60
  local attempt=1
  log "Waiting for \${NAS_HOSTNAME}..."
  while [[ \${attempt} -le \${max_attempts} ]]; do
    if ping -c 1 -W 5000 "\${NAS_HOSTNAME}" >/dev/null 2>&1; then
      log "Network connectivity established (attempt \${attempt})"
      return 0
    fi
    sleep 5
    ((attempt += 1))
  done
  log "ERROR: Cannot reach \${NAS_HOSTNAME} after \${max_attempts} attempts"
  return 1
}

main() {
  log "Starting NAS mount for _transmission"

  # Check if already mounted
  if mount | grep -q "\${MOUNT_POINT}"; then
    log "Already mounted at \${MOUNT_POINT}"
    exit 0
  fi

  wait_for_network || exit 1

  mkdir -p "\${MOUNT_POINT}"

  # Retrieve NAS password from System keychain (this script runs as root LaunchDaemon,
  # so we must specify the System keychain explicitly — root's default keychain is empty)
  local nas_password
  nas_password=\$(security find-generic-password -s "plex-nas-${HOSTNAME_LOWER}" -a "${NAS_USERNAME}" -w /Library/Keychains/System.keychain 2>/dev/null) || {
    log "ERROR: Cannot retrieve NAS password from System keychain (service: plex-nas-${HOSTNAME_LOWER})"
    log "Ensure the credential was imported to /Library/Keychains/System.keychain during first-boot"
    exit 1
  }

  # URL-encode the password via stdin to Python (never interpolate passwords into code)
  local encoded_password
  encoded_password=\$(printf '%s' "\${nas_password}" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=''))")

  if mount_smbfs -o soft,noowners \
    "//${NAS_USERNAME}:\${encoded_password}@\${NAS_HOSTNAME}/\${NAS_SHARE_NAME}" \
    "\${MOUNT_POINT}"; then
    log "NAS mounted at \${MOUNT_POINT}"

    # Apply ACL so _transmission can traverse
    chmod +a "_transmission allow read,execute,list,search" "\${MOUNT_POINT}" 2>/dev/null || true

    chown _transmission:_transmission "\${MOUNT_POINT}" 2>/dev/null || true
  else
    log "ERROR: Failed to mount NAS"
    exit 1
  fi
}

main "\$@"
MOUNT_EOF

  sudo chmod 755 "${mount_script}"
  sudo chown root:wheel "${mount_script}"

  # Create LaunchDaemon plist
  log "Creating NAS mount LaunchDaemon at ${plist_path}..."

  sudo tee "${plist_path}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.mount-nas-transmission</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${mount_script}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/lib/transmission/${HOSTNAME_LOWER}-mount-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/var/lib/transmission/${HOSTNAME_LOWER}-mount-stderr.log</string>
</dict>
</plist>
EOF

  sudo chown root:wheel "${plist_path}"
  sudo chmod 644 "${plist_path}"

  if sudo plutil -lint "${plist_path}" >/dev/null 2>&1; then
    show_log "NAS mount LaunchDaemon created and validated"
  else
    log_error "Invalid plist syntax in ${plist_path}"
    return 1
  fi
}

# ============================================================================
# STAGE 4d: PF kill-switch rules
# ============================================================================

deploy_pf_rules() {
  set_section "Deploying PF Kill-Switch Rules"

  local anchor_file="/etc/pf.anchors/transmission-killswitch"
  local source_file="${SETUP_DIR}/config/transmission-killswitch.conf"

  if [[ ! -f "${source_file}" ]]; then
    log_error "PF rules file not found: ${source_file}"
    return 1
  fi

  # Deploy anchor file
  log "Deploying PF anchor to ${anchor_file}..."
  sudo -p "[VPN Kill-Switch] Enter password to deploy PF rules: " \
    cp "${source_file}" "${anchor_file}"
  sudo chown root:wheel "${anchor_file}"
  sudo chmod 644 "${anchor_file}"
  show_log "PF anchor deployed to ${anchor_file}"

  # Add anchor reference to /etc/pf.conf if not already present
  local anchor_line='anchor "transmission-killswitch"'
  local load_line='load anchor "transmission-killswitch" from "/etc/pf.anchors/transmission-killswitch"'

  if ! grep -q "transmission-killswitch" /etc/pf.conf 2>/dev/null; then
    log "Adding anchor to /etc/pf.conf..."
    # Append anchor reference after existing anchors
    echo "" | sudo tee -a /etc/pf.conf >/dev/null
    echo "# Transmission VPN kill-switch (Stage 4)" | sudo tee -a /etc/pf.conf >/dev/null
    echo "${anchor_line}" | sudo tee -a /etc/pf.conf >/dev/null
    echo "${load_line}" | sudo tee -a /etc/pf.conf >/dev/null
    show_log "Anchor added to /etc/pf.conf"
  else
    log "Anchor already present in /etc/pf.conf"
  fi

  # Create LaunchDaemon to load PF rules at boot
  local pf_plist="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.pf-killswitch.plist"

  log "Creating PF loader LaunchDaemon at ${pf_plist}..."

  # Use a shell wrapper: load rules, then enable with -E (reference-counted, never fails if already enabled)
  sudo tee "${pf_plist}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.pf-killswitch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>/sbin/pfctl -f /etc/pf.conf &amp;&amp; /sbin/pfctl -E</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

  sudo chown root:wheel "${pf_plist}"
  sudo chmod 644 "${pf_plist}"

  if sudo plutil -lint "${pf_plist}" >/dev/null 2>&1; then
    show_log "PF loader LaunchDaemon created and validated"
  else
    log_error "Invalid plist syntax in ${pf_plist}"
    return 1
  fi
}

# ============================================================================
# STAGE 4f: transmission-daemon LaunchDaemon
# ============================================================================

create_daemon_launchdaemon() {
  set_section "Creating transmission-daemon LaunchDaemon"

  local plist_path="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.transmission-daemon.plist"
  local daemon_bin="/opt/homebrew/bin/transmission-daemon"

  # Verify transmission-daemon exists
  if [[ ! -x "${daemon_bin}" ]]; then
    log "transmission-daemon not found at ${daemon_bin}"
    log "Install with: brew install transmission-cli"
    log_error "transmission-daemon binary not found"
    return 1
  fi

  # Create wrapper script that waits for NAS mount before starting daemon
  local wrapper_script="/var/lib/transmission/start-daemon.sh"
  local mount_point="/var/lib/transmission/mnt/${NAS_SHARE_NAME}"

  log "Creating daemon wrapper script at ${wrapper_script}..."

  sudo -p "[VPN Kill-Switch] Enter password to create daemon wrapper: " \
    tee "${wrapper_script}" >/dev/null <<WRAPPER_EOF
#!/usr/bin/env bash
# Wait for NAS mount before starting transmission-daemon
set -euo pipefail

MOUNT_POINT="${mount_point}"
MAX_WAIT=300  # 5 minutes
WAITED=0

while [[ ! -d "\${MOUNT_POINT}/Media" ]] && [[ \${WAITED} -lt \${MAX_WAIT} ]]; do
  sleep 5
  WAITED=\$((WAITED + 5))
done

if [[ ! -d "\${MOUNT_POINT}/Media" ]]; then
  echo "ERROR: NAS not mounted at \${MOUNT_POINT} after \${MAX_WAIT}s" >&2
  exit 1
fi

# Verify PF kill-switch rules are loaded before allowing traffic
if ! /sbin/pfctl -sr 2>/dev/null | grep -q "transmission-killswitch"; then
  echo "ERROR: PF kill-switch rules not loaded — refusing to start without firewall protection" >&2
  exit 1
fi

exec ${daemon_bin} --foreground --config-dir /var/lib/transmission/.config/transmission-daemon
WRAPPER_EOF

  sudo chmod 755 "${wrapper_script}"
  sudo chown root:wheel "${wrapper_script}"

  log "Creating transmission-daemon LaunchDaemon at ${plist_path}..."

  sudo tee "${plist_path}" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.${HOSTNAME_LOWER}.transmission-daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${wrapper_script}</string>
  </array>
  <key>UserName</key>
  <string>_transmission</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>360</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>/var/lib/transmission</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>/var/lib/transmission/${HOSTNAME_LOWER}-daemon-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/var/lib/transmission/${HOSTNAME_LOWER}-daemon-stderr.log</string>
</dict>
</plist>
EOF

  sudo chown root:wheel "${plist_path}"
  sudo chmod 644 "${plist_path}"

  if sudo plutil -lint "${plist_path}" >/dev/null 2>&1; then
    show_log "transmission-daemon LaunchDaemon created and validated"
  else
    log_error "Invalid plist syntax in ${plist_path}"
    return 1
  fi
}

# ============================================================================
# STAGE 4c: Generate settings.json for transmission-daemon
# ============================================================================

generate_settings_json() {
  set_section "Generating transmission-daemon settings.json"

  local settings_file="/var/lib/transmission/.config/transmission-daemon/settings.json"

  if [[ -f "${settings_file}" ]]; then
    log "settings.json already exists, backing up..."
    local backup_timestamp
    backup_timestamp=$(date +%Y%m%d%H%M%S)
    sudo cp "${settings_file}" "${settings_file}.bak.${backup_timestamp}"
  fi

  log "Creating settings.json with translated plist values..."

  # RPC password — use hostname_lower matching existing convention
  local rpc_password="${HOSTNAME_LOWER}"

  # NAS download path (via _transmission's mount)
  local download_dir="/var/lib/transmission/mnt/${NAS_SHARE_NAME}/Media/Torrents/pending-move"

  # Watch directory (synced by rclone under operator, readable by _transmission)
  local watch_dir="${OPERATOR_HOME}/.local/sync/dropbox"

  # Completion script
  local done_script="/var/lib/transmission/.local/bin/transmission-done.sh"

  sudo tee "${settings_file}" >/dev/null <<SETTINGS_EOF
{
    "alt-speed-down": 50,
    "alt-speed-enabled": false,
    "alt-speed-time-begin": 540,
    "alt-speed-time-day": 127,
    "alt-speed-time-enabled": false,
    "alt-speed-time-end": 1020,
    "alt-speed-up": 50,
    "bind-address-ipv4": "0.0.0.0",
    "bind-address-ipv6": "::",
    "blocklist-enabled": true,
    "blocklist-url": "https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz",
    "cache-size-mb": 4,
    "dht-enabled": true,
    "download-dir": "${download_dir}",
    "download-queue-enabled": false,
    "download-queue-size": 3,
    "encryption": 2,
    "idle-seeding-limit": 30,
    "idle-seeding-limit-enabled": true,
    "incomplete-dir-enabled": false,
    "lpd-enabled": true,
    "message-level": 2,
    "peer-congestion-algorithm": "",
    "peer-id-ttl-hours": 6,
    "peer-limit-global": 2048,
    "peer-limit-per-torrent": 256,
    "peer-port": 40944,
    "peer-port-random-on-start": false,
    "peer-socket-tos": "default",
    "pex-enabled": true,
    "port-forwarding-enabled": true,
    "preallocation": 1,
    "prefetch-enabled": true,
    "queue-stalled-enabled": true,
    "queue-stalled-minutes": 30,
    "ratio-limit": 2,
    "ratio-limit-enabled": true,
    "rename-partial-files": true,
    "rpc-authentication-required": true,
    "rpc-bind-address": "0.0.0.0",
    "rpc-enabled": true,
    "rpc-host-whitelist": "",
    "rpc-host-whitelist-enabled": false,
    "rpc-password": "${rpc_password}",
    "rpc-port": 19091,
    "rpc-url": "/transmission/",
    "rpc-username": "${HOSTNAME_LOWER}",
    "rpc-whitelist": "127.0.0.1,192.168.*.*",
    "rpc-whitelist-enabled": true,
    "scrape-paused-torrents-enabled": true,
    "script-torrent-done-enabled": true,
    "script-torrent-done-filename": "${done_script}",
    "seed-queue-enabled": false,
    "seed-queue-size": 3,
    "speed-limit-down": 100000,
    "speed-limit-down-enabled": false,
    "speed-limit-up": 1000,
    "speed-limit-up-enabled": false,
    "start-added-torrents": true,
    "trash-original-torrent-files": true,
    "umask": 18,
    "upload-slots-per-torrent": 14,
    "utp-enabled": true,
    "watch-dir": "${watch_dir}",
    "watch-dir-enabled": true
}
SETTINGS_EOF

  sudo chown _transmission:_transmission "${settings_file}"
  sudo chmod 600 "${settings_file}"

  show_log "settings.json generated at ${settings_file}"
}

# ============================================================================
# Main
# ============================================================================

main() {
  section "VPN Kill-Switch Setup (Stage 4)"
  log "Server: ${HOSTNAME}"
  log "Operator: ${OPERATOR_USERNAME}"

  echo ""
  echo "This script will:"
  echo "  1. Create _transmission system account"
  echo "  2. Create data directories in /var/lib/transmission"
  echo "  3. Create system-level NAS mount for _transmission"
  echo "  4. Deploy PF kill-switch rules"
  echo "  5. Create transmission-daemon LaunchDaemon"
  echo "  6. Generate transmission-daemon settings.json"
  echo ""
  echo "PREREQUISITES:"
  echo "  - Stage 3 (pf-test-user.sh) must have PASSED"
  echo "  - Stages 1-2 must be stable"
  echo ""

  if ! confirm "Proceed with Stage 4 VPN kill-switch setup?" "y"; then
    log "Setup cancelled by user"
    exit 0
  fi

  create_transmission_user
  create_data_directories
  create_nas_mount_daemon
  deploy_pf_rules
  create_daemon_launchdaemon
  generate_settings_json

  section "Stage 4 Setup Complete"
  show_log ""
  show_log "VPN kill-switch setup completed. Next steps:"
  show_log ""
  show_log "  1. Migrate existing torrents/resume data to /var/lib/transmission/"
  show_log "  2. Copy FileBot license to /var/lib/transmission/.filebot/"
  show_log "  3. Adapt transmission-done.sh for _transmission context"
  show_log "  4. Pre-configure LuLu to allow transmission-daemon"
  show_log "  5. Stop Transmission.app and disable its LaunchAgent"
  show_log "  6. Load LaunchDaemons:"
  show_log "     sudo launchctl load /Library/LaunchDaemons/com.${HOSTNAME_LOWER}.mount-nas-transmission.plist"
  show_log "     sudo launchctl load /Library/LaunchDaemons/com.${HOSTNAME_LOWER}.pf-killswitch.plist"
  show_log "     sudo launchctl load /Library/LaunchDaemons/com.${HOSTNAME_LOWER}.transmission-daemon.plist"
  show_log ""
  show_log "  ROLLBACK: Unload daemons, flush PF rules, re-enable Transmission.app LaunchAgent"
  show_log ""
}

main "$@"
exit 0
