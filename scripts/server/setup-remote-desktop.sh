#!/bin/bash

# Simple Remote Desktop setup for macOS with direct launchd configuration
# This script enables Screen Sharing and Remote Management using system commands

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="${0##*/}"
readonly LOG_PREFIX="[Remote Desktop Setup]"
readonly DEFAULT_OVERRIDES_PERMS="0644"

# Logging function
log() {
  echo "${LOG_PREFIX} $*" >&2
}

# Show usage information
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Simple Remote Desktop setup for macOS with direct system configuration.

OPTIONS:
    --force             Skip confirmation prompts
    --help              Show this help message

DESCRIPTION:
    This script provides a clean approach to Remote Desktop setup:
    1. Disables existing remote desktop services for a clean state
    2. Enables Screen Sharing using direct launchd commands
    3. Configures Remote Management service
    4. Verifies final configuration and provides connection information

NOTES:
    - Requires administrator privileges
    - Uses direct system commands for reliable configuration
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

# Disable all remote desktop services (for clean slate)
disable_all_services() {
  log "Disabling existing remote desktop services for clean setup..."

  # Disable Remote Management
  sudo -p "${LOG_PREFIX} Enter password to disable existing services: " \
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -deactivate -stop 2>/dev/null || true

  # Disable Screen Sharing
  sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist &>/dev/null || true

  # Clear any conflicting settings
  local overrides_plist="/var/db/launchd.db/com.apple.launchd/overrides.plist"
  local original_perms

  if [[ -f "${overrides_plist}" ]]; then
    # Capture current permissions before modifying
    original_perms=$(stat -f "%Mp%Lp" "${overrides_plist}" 2>/dev/null || echo "${DEFAULT_OVERRIDES_PERMS}")

    # Delete the conflicting setting
    sudo defaults delete "${overrides_plist}" com.apple.screensharing &>/dev/null || true

    # Restore permissions if file still exists after deletion
    if [[ -f "${overrides_plist}" ]]; then
      if [[ "${original_perms}" =~ ^[0-7]*4[4-7]$ ]] || [[ "${original_perms}" =~ ^[0-7]*6[4-7]$ ]]; then
        sudo chmod "${original_perms}" "${overrides_plist}"
      else
        sudo chmod a+r "${overrides_plist}"
      fi
    fi
  fi

  # Wait for services to fully stop
  sleep 2

  log "Existing services disabled"
}

# Enable basic Remote Management service
enable_remote_management_service() {
  log "Enabling Remote Management service..."

  # Capture kickstart output with verbose flag
  local kickstart_output
  kickstart_output=$(sudo -p "${LOG_PREFIX} Enter password to configure Remote Management: " \
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -users admin -privs -all -restart -agent -menu -verbose 2>&1) || {
    log "WARNING: kickstart failed or had limited functionality"
    log "Output: ${kickstart_output}"
    return 1
  }

  # Check if output indicates success
  if echo "${kickstart_output}" | grep -q "Activated Remote Management" \
    && echo "${kickstart_output}" | grep -q "Done"; then
    log "✓ Remote Management service configured successfully"
    log "Output: ${kickstart_output}"
    return 0
  else
    log "⚠️ Remote Management configuration may have failed"
    log "Output: ${kickstart_output}"
    return 1
  fi
}

# Enable Screen Sharing using direct launchd commands
setup_screen_sharing() {
  log "Enabling Screen Sharing service..."

  local overrides_plist="/var/db/launchd.db/com.apple.launchd/overrides.plist"
  local original_perms

  # Capture current permissions to restore them later
  if [[ -f "${overrides_plist}" ]]; then
    original_perms=$(stat -f "%Mp%Lp" "${overrides_plist}" 2>/dev/null || echo "${DEFAULT_OVERRIDES_PERMS}")
    log "Current overrides.plist permissions: ${original_perms}"
  else
    # Default permissions for new file
    original_perms="${DEFAULT_OVERRIDES_PERMS}"
    log "overrides.plist does not exist - will use default permissions: ${original_perms}"
  fi

  # Enable Screen Sharing in launchd overrides
  sudo -p "${LOG_PREFIX} Enter password to enable Screen Sharing: " \
    defaults write "${overrides_plist}" com.apple.screensharing -dict Disabled -bool false

  # Restore original permissions (ensuring at least a+r access)
  if [[ "${original_perms}" =~ ^[0-7]*4[4-7]$ ]] || [[ "${original_perms}" =~ ^[0-7]*6[4-7]$ ]]; then
    # Original permissions already have a+r, restore them
    sudo chmod "${original_perms}" "${overrides_plist}"
    log "Restored original permissions: ${original_perms}"
  else
    # Original permissions didn't have a+r, ensure a+r access
    sudo chmod a+r "${overrides_plist}"
    log "Applied a+r permissions for launchd access"
  fi

  # Unload Screen Sharing service (if running) to ensure clean state
  sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist &>/dev/null || true

  # Load Screen Sharing service
  sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist

  log "✓ Screen Sharing service enabled"
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

    # Close System Settings now that user is done with configuration
    log "Closing System Settings..."
    osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true
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

  # Confirmation prompt
  if [[ "${force}" != "true" ]]; then
    echo "${LOG_PREFIX} This script will:"
    echo "${LOG_PREFIX} 1. Disable existing remote desktop services"
    echo "${LOG_PREFIX} 2. Enable Screen Sharing using direct system commands"
    echo "${LOG_PREFIX} 3. Enable Remote Management service"
    echo "${LOG_PREFIX} 4. Configure Remote Management if needed"
    echo "${LOG_PREFIX} 5. Verify the final setup"
    echo ""
    echo "${LOG_PREFIX} This requires administrator privileges."
    read -p "${LOG_PREFIX} Continue? (Y/n): " -n 1 -r response
    echo
    case ${response} in
      [nN])
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
  if enable_remote_management_service; then
    log "✓ Remote Management configured successfully - skipping manual setup"
  else
    log "Automated Remote Management setup failed - requiring manual configuration"
    setup_remote_management
  fi

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
