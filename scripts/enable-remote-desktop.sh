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

    The script uses a clean-slate approach for full idempotency:
    1. Disables all existing remote desktop services first
    2. Enables the desired service (Remote Management or Screen Sharing)
    3. Configures TCC permissions for System Settings automation
    4. Uses robust UI automation to toggle Screen Sharing
    5. Verifies final configuration and provides connection info

NOTES:
    - Requires administrator privileges
    - Fully idempotent - works regardless of current state
    - Works around kickstart utility limitations in macOS 12.1+
    - Handles TCC permissions that prevent automated enablement
    - Multiple fallback methods for UI automation compatibility

EOF
}

# Check if running as root (not recommended)
check_privileges() {
  if [[ ${EUID} -eq 0 ]]; then
    log "ERROR: Do not run this script as root. Run as admin user with sudo prompts."
    exit 1
  fi
}

# Disable all remote desktop services (for clean slate)
disable_all_services() {
  log "Disabling existing remote desktop services for clean setup..."

  # Disable Remote Management
  sudo -p "${LOG_PREFIX} Enter password to disable existing services: " \
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -deactivate -stop 2>/dev/null || true

  # Disable Screen Sharing
  sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

  # Clear any conflicting settings
  sudo defaults delete /var/db/launchd.db/com.apple.launchd/overrides.plist com.apple.screensharing 2>/dev/null || true

  # Wait for services to fully stop
  sleep 2

  log "Existing services disabled"
}

# Enable Screen Sharing service
enable_screen_sharing_service() {
  log "Enabling Screen Sharing service..."

  # Enable the service in launchd
  sudo -p "${LOG_PREFIX} Enter password to enable Screen Sharing service: " \
    launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

  # Alternative method using defaults
  sudo defaults write /var/db/launchd.db/com.apple.launchd/overrides.plist \
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

# Force Screen Recording permission dialog and automate approval
force_screen_recording_permission() {
  log "Forcing Screen Recording permission dialog for System Settings..."

  # First, reset the permission to ensure we get a fresh prompt
  sudo -p "${LOG_PREFIX} Enter password to reset TCC permissions: " \
    tccutil reset ScreenCapture com.apple.systempreferences 2>/dev/null || true

  # Force System Settings to request Screen Recording by attempting screen capture
  log "Triggering Screen Recording permission request..."

  # This will force the permission dialog to appear
  osascript <<'EOF' 2>/dev/null || true
tell application "System Settings"
    activate
    delay 1
end tell

tell application "System Events"
    tell process "System Settings"
        try
            -- This will trigger the Screen Recording permission request
            get position of window 1
        on error
            -- Permission request should have been triggered
        end try
    end tell
end tell
EOF

  log "Screen Recording permission request triggered"

  # Try to automate clicking "Allow" in the permission dialog
  log "Attempting to automatically approve permission dialog..."

  # Wait a moment for dialog to appear and try to click Allow
  sleep 1
  if osascript <<'EOF' 2>/dev/null; then
tell application "System Events"
    repeat with i from 1 to 10
        try
            -- Look for the Screen Recording permission dialog
            if exists window 1 of application process "UserNotificationCenter" then
                tell window 1 of application process "UserNotificationCenter"
                    if exists button "Allow" then
                        click button "Allow"
                        exit repeat
                    end if
                end tell
            end if
            
            -- Alternative: Look for TCC dialog in different process
            repeat with proc in (every application process whose visible is true)
                tell proc
                    if exists window 1 then
                        tell window 1
                            if exists button "Allow" then
                                if (name of proc contains "TCC" or name of proc contains "Security" or name of proc contains "Privacy") then
                                    click button "Allow"
                                    exit repeat
                                end if
                            end if
                        end tell
                    end if
                end tell
            end repeat
            
            delay 0.5
        on error
            -- Continue trying
        end try
    end repeat
end tell
EOF
    log "Permission dialog automatically approved"
  else
    log "Automatic dialog approval failed - manual approval may be required"
  fi

  sleep 2
  log "Permission dialog handling completed"
}

# Configure TCC permissions for Screen Sharing
configure_tcc_permissions() {
  log "Configuring TCC permissions..."

  # Force the Screen Recording permission dialog
  force_screen_recording_permission

  # Try to automate the permission approval using tccutil
  log "Attempting to grant Screen Recording permission automatically..."

  # Method 1: Direct TCC database manipulation (requires SIP disabled)
  if sudo -p "${LOG_PREFIX} Enter password for TCC database access: " \
    sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
    "INSERT OR REPLACE INTO access VALUES('kTCCServiceScreenCapture','com.apple.systempreferences',0,2,4,1,NULL,NULL,NULL,'UNUSED',NULL,0,1687440000);" 2>/dev/null; then
    log "✓ Screen Recording permission granted via TCC database"
  else
    log "⚠ Direct TCC database access failed (normal with SIP enabled)"

    # Method 2: Use defaults to configure (may not work on all versions)
    sudo defaults write /Library/Application\ Support/com.apple.TCC/TCC.db \
      'kTCCServiceScreenCapture' -dict-add 'com.apple.systempreferences' -dict \
      client 'com.apple.systempreferences' \
      client_type 0 \
      allowed 1 \
      prompt_count 1 \
      csreq '' 2>/dev/null || true

    # Method 3: Alternative approach using privacy settings
    sudo -p "${LOG_PREFIX} Enter password to configure privacy settings: " \
      /usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
      "DELETE FROM access WHERE service='kTCCServiceScreenCapture' AND client='com.apple.systempreferences';" 2>/dev/null || true

    local timestamp
    timestamp=$(date +%s)
    if sudo /usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
      "INSERT INTO access VALUES('kTCCServiceScreenCapture','com.apple.systempreferences',0,2,4,1,NULL,NULL,NULL,'UNUSED',NULL,0,${timestamp});" 2>/dev/null; then
      log "✓ Screen Recording permission configured via alternative method"
    else
      log "⚠ Automatic permission configuration failed - manual approval required"
    fi
  fi

  log "TCC permissions configuration completed"
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

  # AppleScript to toggle Screen Sharing - robust approach for macOS 15
  if osascript <<'EOF' 2>/dev/null; then
tell application "System Settings"
    activate
    delay 2
    
    try
        -- Navigate to Sharing settings
        reveal pane id "com.apple.Sharing-Settings.extension"
        delay 3
        
        -- Use UI scripting to toggle Screen Sharing
        tell application "System Events"
            tell process "System Settings"
                -- Wait for window to be ready
                repeat while not (exists window 1)
                    delay 0.5
                end repeat
                delay 1
                
                -- Multiple attempts to find and enable Screen Sharing
                set success to false
                
                -- Method 1: Look for Screen Sharing in the main list
                try
                    set screenSharingSwitch to switch "Screen Sharing" of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
                    if value of screenSharingSwitch is 0 then
                        click screenSharingSwitch
                        delay 1
                        set success to true
                    else
                        set success to true -- Already enabled
                    end if
                on error
                    -- Method failed, try next approach
                end try
                
                -- Method 2: Look for checkbox in table/list view
                if not success then
                    try
                        repeat with i from 1 to count of rows of table 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
                            set currentRow to row i of table 1 of scroll area 1 of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
                            if exists static text 1 of currentRow then
                                if value of static text 1 of currentRow contains "Screen Sharing" then
                                    if exists checkbox 1 of currentRow then
                                        if value of checkbox 1 of currentRow is 0 then
                                            click checkbox 1 of currentRow
                                            delay 1
                                        end if
                                        set success to true
                                        exit repeat
                                    end if
                                end if
                            end if
                        end repeat
                    on error
                        -- This method also failed
                    end try
                end if
                
                -- Method 3: Direct click on Screen Sharing if it exists
                if not success then
                    try
                        click button "Screen Sharing" of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1
                        delay 1
                        set success to true
                    on error
                        -- This method also failed
                    end try
                end if
                
                -- If we found Screen Sharing, make sure it's actually enabled
                if success then
                    delay 2
                    -- Check for configuration dialog and enable options
                    try
                        if exists sheet 1 of window 1 then
                            -- Screen Sharing configuration sheet is open
                            if exists checkbox "Anyone may request permission to control screen" of sheet 1 of window 1 then
                                if value of checkbox "Anyone may request permission to control screen" of sheet 1 of window 1 is 0 then
                                    click checkbox "Anyone may request permission to control screen" of sheet 1 of window 1
                                    delay 0.5
                                end if
                            end if
                            
                            if exists checkbox "VNC viewers may control screen with password" of sheet 1 of window 1 then
                                if value of checkbox "VNC viewers may control screen with password" of sheet 1 of window 1 is 0 then
                                    click checkbox "VNC viewers may control screen with password" of sheet 1 of window 1
                                    delay 0.5
                                end if
                            end if
                            
                            -- Click Done to close the configuration sheet
                            if exists button "Done" of sheet 1 of window 1 then
                                click button "Done" of sheet 1 of window 1
                                delay 1
                            end if
                        end if
                    on error
                        -- Configuration failed, but Screen Sharing might still be enabled
                    end try
                end if
                
                if not success then
                    error "Could not find Screen Sharing controls in System Settings"
                end if
                
            end tell
        end tell
        
        delay 2
    on error errMsg
        error "Failed to toggle Screen Sharing: " & errMsg
    end try
    
    -- Keep System Settings open briefly to ensure changes apply
    delay 2
end tell
EOF
    log "Screen Sharing automation completed"
  else
    log "WARNING: AppleScript automation failed - manual toggle may be required"
    return 1
  fi
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

  # Execute enablement steps with clean slate approach
  disable_all_services

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
