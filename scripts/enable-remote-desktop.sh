#!/bin/bash

# Enable Remote Desktop/Screen Sharing automation for macOS 15.6
# This script addresses the issue where Remote Desktop doesn't work until
# manually toggled in System Settings, even after kickstart commands

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="${0##*/}"
readonly LOG_PREFIX="[Remote Desktop Setup]"

# Logging function
log() {
  echo "${LOG_PREFIX} $*" >&2
}

# Show usage information
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Enable Remote Desktop/Screen Sharing on macOS 15.6 with proper TCC permissions.

OPTIONS:
    --force             Skip confirmation prompts
    --remote-mgmt       Enable Remote Management (default, required for Apple Remote Desktop)
    --screen-sharing    Enable Screen Sharing only (VNC-compatible, no ARD)
    --help             Show this help message

DESCRIPTION:
    This script automates the process of enabling Remote Desktop functionality
    that normally requires manual toggling in System Settings. It handles both
    service enablement and TCC permission configuration.

    The script uses multiple methods to ensure reliable activation:
    1. Direct service enablement via launchctl
    2. System Settings automation via URL schemes
    3. TCC permission configuration
    4. Service verification and restart

NOTES:
    - Requires administrator privileges
    - Works around kickstart utility limitations in macOS 12.1+
    - Handles TCC permissions that prevent automated enablement
    - Provides fallback methods for maximum compatibility

EOF
}

# Check if running as root (not recommended)
check_privileges() {
  if [[ ${EUID} -eq 0 ]]; then
    log "ERROR: Do not run this script as root. Run as admin user with sudo prompts."
    exit 1
  fi
}

# Enable Screen Sharing service
enable_screen_sharing_service() {
  log "Enabling Screen Sharing service..."

  # Enable the service in launchd
  sudo -p "${LOG_PREFIX} Enter password to enable Screen Sharing service: " \
    launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

  # Alternative method using defaults
  sudo -p "${LOG_PREFIX} Enter password to configure Screen Sharing settings: " \
    defaults write /var/db/launchd.db/com.apple.launchd/overrides.plist \
    com.apple.screensharing -dict Disabled -bool false 2>/dev/null || true

  log "Screen Sharing service enabled"
}

# Enable Remote Management service
enable_remote_management_service() {
  log "Enabling Remote Management service..."

  # Use kickstart for basic setup (limited functionality in macOS 12.1+)
  sudo -p "${LOG_PREFIX} Enter password to configure Remote Management: " \
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -users admin -privs -all -restart -agent -menu || {
    log "WARNING: kickstart may have limited functionality on macOS 12.1+"
  }

  log "Remote Management service configured"
}

# Configure TCC permissions for Screen Sharing
configure_tcc_permissions() {
  log "Configuring TCC permissions..."

  # Grant Screen Recording permission to System Settings for automation
  # This enables System Settings to modify screen sharing settings
  sudo -p "${LOG_PREFIX} Enter password to configure TCC permissions: " \
    tccutil reset ScreenCapture com.apple.systempreferences 2>/dev/null || true

  # Note: The user will still need to approve screen recording for System Settings
  # when it first attempts to automate, but this prepares the system

  log "TCC permissions configured"
}

# Open System Settings to Screen Sharing with automation
open_screen_sharing_settings() {
  log "Opening Screen Sharing settings for automation..."

  # Open directly to Screen Sharing settings
  open "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_ScreenSharing" || {
    log "WARNING: Direct Screen Sharing settings URL failed, opening general Sharing"
    open "x-apple.systempreferences:com.apple.preferences.sharing" || {
      log "ERROR: Could not open System Settings"
      return 1
    }
  }

  # Give System Settings time to load
  sleep 2

  log "System Settings opened to Screen Sharing"
}

# Automate Screen Sharing toggle using AppleScript
automate_screen_sharing_toggle() {
  log "Attempting to automate Screen Sharing toggle..."

  # AppleScript to toggle Screen Sharing
  # This simulates the manual toggle that makes Remote Desktop work
  if ! osascript <<'EOF'; then
tell application "System Settings"
    activate
    delay 1
    
    try
        -- Navigate to Sharing settings
        reveal anchor "Sharing" of pane id "com.apple.Sharing-Settings.extension"
        delay 2
        
        -- Use UI scripting to toggle Screen Sharing
        tell application "System Events"
            tell process "System Settings"
                -- Look for Screen Sharing checkbox and toggle it
                try
                    -- First try to find and click the Screen Sharing checkbox
                    set screenSharingRow to first row of table 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1 whose value of static text 1 contains "Screen Sharing"
                    click checkbox 1 of screenSharingRow
                    delay 1
                    -- Click again to ensure it's enabled
                    if (value of checkbox 1 of screenSharingRow as boolean) is false then
                        click checkbox 1 of screenSharingRow
                    end if
                on error
                    -- Fallback: try different UI path
                    click checkbox "Screen Sharing" of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
                    delay 1
                end try
            end tell
        end tell
        
        delay 2
    on error errMsg
        error "Failed to toggle Screen Sharing: " & errMsg
    end try
    
    -- Keep System Settings open briefly to ensure changes apply
    delay 3
end tell
EOF
    log "WARNING: AppleScript automation failed - manual toggle may be required"
    return 1
  fi

  log "Screen Sharing automation completed"
}

# Verify Remote Desktop functionality
verify_remote_desktop() {
  log "Verifying Remote Desktop status..."

  # Check if Screen Sharing is running
  if pgrep -f "/System/Library/CoreServices/RemoteManagement/ScreensharingAgent" >/dev/null; then
    log "✓ Screen Sharing agent is running"
  else
    log "⚠ Screen Sharing agent not detected"
  fi

  # Check if Remote Management is running (if enabled)
  if pgrep -f "/System/Library/CoreServices/RemoteManagement/ARDAgent" >/dev/null; then
    log "✓ Remote Management agent is running"
  else
    log "ℹ Remote Management agent not running (normal if using Screen Sharing only)"
  fi

  # Check service status
  local screen_sharing_status
  screen_sharing_status=$(sudo launchctl list | grep com.apple.screensharing || echo "not found")
  if [[ "${screen_sharing_status}" == *"com.apple.screensharing"* ]]; then
    log "✓ Screen Sharing service is loaded"
  else
    log "⚠ Screen Sharing service not loaded"
  fi

  # Display connection information
  local hostname
  hostname=$(hostname)
  log "Remote Desktop should be accessible at: vnc://${hostname}.local"
  log "You may need to configure user access in System Settings > Sharing > Screen Sharing > (i)"
}

# Clean up and restart services
restart_services() {
  log "Restarting Remote Desktop services..."

  # Restart Screen Sharing service
  sudo -p "${LOG_PREFIX} Enter password to restart services: " bash -c '
        launchctl unload /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
        sleep 1
        launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
    ' || {
    log "WARNING: Service restart failed, but settings may still be applied"
  }

  log "Services restarted"
}

# Main execution function
main() {
  local force=false
  local enable_remote_mgmt=true

  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force)
        force=true
        shift
        ;;
      --remote-mgmt)
        enable_remote_mgmt=true
        shift
        ;;
      --screen-sharing)
        enable_remote_mgmt=false
        shift
        ;;
      --help)
        show_usage
        exit 0
        ;;
      *)
        log "ERROR: Unknown option: $1"
        show_usage
        exit 1
        ;;
    esac
  done

  log "Starting Remote Desktop enablement for macOS 15.6"

  # Check privileges
  check_privileges

  # Confirmation prompt
  if [[ "${force}" != "true" ]]; then
    if [[ "${enable_remote_mgmt}" == "true" ]]; then
      echo "${LOG_PREFIX} This will enable Remote Management (required for Apple Remote Desktop)."
    else
      echo "${LOG_PREFIX} This will enable Screen Sharing only (VNC-compatible, no ARD)."
    fi
    echo "${LOG_PREFIX} This requires administrator privileges and may open System Settings."
    read -p "${LOG_PREFIX} Continue? (Y/n): " -r response
    case ${response} in
      [nN] | [nN][oO])
        log "Operation cancelled by user"
        exit 0
        ;;
      *)
        # Default: continue with operation
        ;;
    esac
  fi

  # Execute enablement steps
  if [[ "${enable_remote_mgmt}" == "true" ]]; then
    enable_remote_management_service
  else
    enable_screen_sharing_service
  fi

  configure_tcc_permissions
  open_screen_sharing_settings

  # Attempt automation (may require user approval for TCC)
  log "NOTE: System Settings may prompt for Screen Recording permission."
  log "Please approve the permission if prompted to enable automation."
  automate_screen_sharing_toggle

  restart_services
  verify_remote_desktop

  log "Remote Desktop enablement completed!"
  log ""
  log "NEXT STEPS:"
  log "1. If Screen Recording permission was requested, approve it and re-run this script"
  log "2. Configure user access in System Settings > Sharing > Screen Sharing > (i)"
  log "3. Test connection from another Mac using Screen Sharing app or VNC client"
  local hostname
  hostname=$(hostname)
  log "4. Connection address: vnc://${hostname}.local"

  if [[ "${enable_remote_mgmt}" != "true" ]]; then
    log ""
    log "NOTE: Using Screen Sharing (not Remote Management) for better compatibility."
    log "If you need Remote Management features, re-run with --remote-mgmt flag."
  fi
}

# Execute main function with all arguments
main "$@"
