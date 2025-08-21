#!/bin/bash

# Simple Remote Desktop setup for macOS with user-guided configuration
# This script handles the service setup and guides users through System Settings

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

Simple Remote Desktop setup for macOS with guided System Settings configuration.

OPTIONS:
    --force             Skip confirmation prompts
    --help              Show this help message

DESCRIPTION:
    This script provides a clean, user-friendly approach to Remote Desktop setup:
    1. Disables existing remote desktop services for a clean state
    2. Enables basic services via command line where possible
    3. Opens System Settings and guides user through manual configuration
    4. Verifies final configuration and provides connection information

NOTES:
    - Requires administrator privileges
    - Works with Apple's security model instead of against it
    - User interaction required for security-sensitive settings
    - Compatible with all macOS versions including 15.6+

EOF
}

# Check if running as root (not recommended)
check_privileges() {
  if [[ ${EUID} -eq 0 ]]; then
    log "ERROR: Do not run this script as root. Run as admin user with sudo prompts."
    exit 1
  fi
}

# Check if running in a GUI session (required for AppleScript dialogs)
check_gui_session() {
  local session_type
  session_type=$(launchctl managername 2>/dev/null || echo "Unknown")

  if [[ "${session_type}" != "Aqua" ]]; then
    log "ERROR: This script requires a GUI session to display AppleScript dialogs and open System Settings."
    log "Current session type: ${session_type}"
    log ""
    log "Remote Desktop setup requires direct access to the Mac's desktop to:"
    log "- Display AppleScript configuration dialogs"
    log "- Open and interact with System Settings"
    log "- Enable Screen Sharing and Remote Management services"
    log ""
    log "Please run this script from the Mac's local desktop session."
    exit 1
  fi

  log "✓ GUI session detected (${session_type}) - AppleScript dialogs available"
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

# Enable basic Remote Management service
enable_remote_management_service() {
  log "Enabling Remote Management service..."

  # Use kickstart for basic setup
  sudo -p "${LOG_PREFIX} Enter password to configure Remote Management: " \
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -users admin -privs -all -restart -agent -menu || {
    log "WARNING: kickstart may have limited functionality on macOS 12.1+"
  }

  log "Remote Management service configured"
}

# Guide user through Screen Sharing setup
setup_screen_sharing() {
  log "Opening Screen Sharing settings for manual configuration..."

  # Open directly to Screen Sharing settings
  if open "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_ScreenSharing"; then
    log "System Settings opened to Screen Sharing"
  else
    log "Opening general Sharing settings..."
    open "x-apple.systempreferences:com.apple.preferences.sharing" || {
      log "WARNING: Could not open System Settings automatically"
      log "Please manually open: System Settings > General > Sharing"
    }
  fi

  # Give System Settings time to load
  sleep 2

  log "System Settings opened - showing Screen Sharing configuration dialog..."

  # Show AppleScript dialog for user confirmation
  if osascript <<'EOF'; then
display dialog "Screen Sharing Configuration - STEP 1

System Settings should now be open to the Sharing page.

IMPORTANT: Screen Sharing must be enabled FIRST, before Remote Management.
Otherwise Remote Management will prevent you from enabling Screen Sharing.

Please complete these steps:
1. Find 'Screen Sharing' in the list
2. Click the toggle switch to turn Screen Sharing ON
3. Configure access settings as needed:
   • 'VNC viewers may control screen with password'
   • Set a password if desired
   • Configure 'Allow access for' (Administrators recommended)
4. Click 'Done' when finished

Click OK when you have completed the Screen Sharing setup." buttons {"Cancel", "OK"} default button "OK" with title "Remote Desktop Setup"
EOF
    log "Screen Sharing configuration completed by user"
  else
    log "User cancelled Screen Sharing setup"
    return 1
  fi
}

# Guide user through Remote Management setup
setup_remote_management() {
  log "Opening Remote Management settings for manual configuration..."

  # Open directly to Remote Management settings
  if open "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_ARDService"; then
    log "System Settings opened to Remote Management"
  else
    log "Opening general Sharing settings..."
    open "x-apple.systempreferences:com.apple.preferences.sharing" || {
      log "WARNING: Could not open System Settings automatically"
      log "Please manually open: System Settings > General > Sharing"
    }
  fi

  # Give System Settings time to load
  sleep 2

  log "System Settings opened - showing Remote Management configuration dialog..."

  # Show AppleScript dialog for user confirmation
  if osascript <<'EOF'; then
display dialog "Remote Management Configuration - STEP 2

System Settings should now be open to the Sharing page.

Screen Sharing should now be ON and Remote Management will take control of it.

Please complete these steps:
1. Find 'Remote Management' in the list (in the Advanced section)
2. Click the toggle switch to turn Remote Management ON
3. Configure access settings when prompted:
   • Select users who can access (Administrators recommended)
   • Choose access privileges (full control recommended for ARD)
   • Set VNC access password if desired
4. Click 'Done' when finished

NOTE: Remote Management is required for Apple Remote Desktop (ARD).
Screen Sharing alone provides VNC access but not full ARD features.

Click OK when you have completed the Remote Management setup." buttons {"Cancel", "OK"} default button "OK" with title "Remote Desktop Setup"
EOF
    log "Remote Management configuration completed by user"
  else
    log "User cancelled Remote Management setup"
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
    log "ℹ Screen Sharing agent not detected (may not be enabled)"
  fi

  # Check if Remote Management is running
  if pgrep -f "/System/Library/CoreServices/RemoteManagement/ARDAgent" >/dev/null; then
    log "✓ Remote Management agent is running"
  else
    log "ℹ Remote Management agent not running (may not be enabled)"
  fi

  # Check service status
  local screen_sharing_status
  screen_sharing_status=$(sudo launchctl list | grep com.apple.screensharing || echo "not found")
  if [[ "${screen_sharing_status}" == *"com.apple.screensharing"* ]]; then
    log "✓ Screen Sharing service is loaded"
  else
    log "ℹ Screen Sharing service not loaded"
  fi

  # Display connection information
  local hostname
  hostname=$(hostname)
  log ""
  log "========================================="
  log "        CONNECTION INFORMATION"
  log "========================================="
  log ""
  log "If Remote Desktop is now enabled, you can connect using:"
  log ""
  log "• VNC URL: vnc://${hostname}.local"
  log "• Screen Sharing: Connect from another Mac using Finder > Go > Connect to Server"
  log "• Apple Remote Desktop: Use ARD app if Remote Management is enabled"
  log ""
  log "Test your connection from another Mac to verify setup is working."
}

# Main execution function
main() {
  local force=false

  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force)
        force=true
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

  log "Starting Remote Desktop setup for macOS"

  # Check prerequisites
  check_privileges
  check_gui_session

  # Confirmation prompt
  if [[ "${force}" != "true" ]]; then
    echo "${LOG_PREFIX} This script will:"
    echo "${LOG_PREFIX} 1. Disable existing remote desktop services"
    echo "${LOG_PREFIX} 2. Guide you through enabling Screen Sharing first"
    echo "${LOG_PREFIX} 3. Enable Remote Management service"
    echo "${LOG_PREFIX} 4. Guide you through Remote Management configuration"
    echo "${LOG_PREFIX} 5. Verify the final setup"
    echo ""
    echo "${LOG_PREFIX} This requires administrator privileges and user interaction."
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

  # Execute setup steps in correct order
  disable_all_services

  # CRITICAL: Screen Sharing must be enabled BEFORE Remote Management
  # Otherwise Remote Management will control Screen Sharing and prevent user from enabling it
  setup_screen_sharing

  # Now enable Remote Management (which will take control of Screen Sharing)
  enable_remote_management_service

  # Guide user through Remote Management configuration
  setup_remote_management

  # Verify final setup
  verify_remote_desktop

  log ""
  log "========================================="
  log "           SETUP COMPLETE"
  log "========================================="
  log ""
  log "Remote Desktop setup completed!"
  log ""
  log "NEXT STEPS:"
  log "• Test the connection from another Mac"
  log "• Configure firewall if needed"
  log "• Set up user accounts with appropriate access"
  log ""
  log "If you experience issues, check System Settings > Sharing"
  log "to verify Screen Sharing and Remote Management are enabled."
}

# Execute main function with all arguments
main "$@"
