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

  if sudo test -f "${overrides_plist}"; then
    # Capture current permissions before modifying
    original_perms=$(stat -f "%Mp%Lp" "${overrides_plist}" 2>/dev/null || echo "${DEFAULT_OVERRIDES_PERMS}")

    # Delete the conflicting setting
    sudo defaults delete "${overrides_plist}" com.apple.screensharing &>/dev/null || true

    # Restore permissions if file still exists after deletion
    if sudo test -f "${overrides_plist}"; then
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
  if sudo test -f "${overrides_plist}"; then
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

# Function to check Screen Sharing status accurately
check_screen_sharing_status() {
  local status="inactive"
  local details=""

  # Check if Screen Sharing is available through dedicated service
  if launchctl list | grep -q com.apple.screensharing; then
    if pgrep -f "/System/Library/CoreServices/RemoteManagement/ScreensharingAgent" >/dev/null 2>&1; then
      status="active"
      details="dedicated Screen Sharing service active"
    else
      status="partial"
      details="Screen Sharing service loaded but agent not running"
    fi
  # Check if Screen Sharing is available through Remote Management
  elif pgrep -f "/System/Library/CoreServices/RemoteManagement/ARDAgent" >/dev/null 2>&1; then
    status="active"
    details="Screen Sharing available via Remote Management"
  else
    details="no Screen Sharing service detected"
  fi

  echo "${status}|${details}"
}

# Function to check Remote Management status accurately
check_remote_management_status() {
  local status="inactive"
  local details=""

  # Check ARDAgent process (most reliable for Remote Management)
  if pgrep -f "/System/Library/CoreServices/RemoteManagement/ARDAgent" >/dev/null 2>&1; then
    status="active"
    details="ARDAgent process running"
  else
    details="ARDAgent process not running"
  fi

  echo "${status}|${details}"
}

# Show GUI dialog with manual instructions when auto-activation fails
show_manual_setup_dialog() {
  log "Showing manual setup instructions dialog..."

  if osascript <<'EOF'; then
display dialog "Remote Desktop Setup Incomplete

Automatic setup was unable to fully activate Remote Desktop services.

Please complete the setup manually:

1. Open System Settings
2. Go to General > Sharing
3. Turn ON 'Screen Sharing' 
4. Turn ON 'Remote Management' (if you need Apple Remote Desktop features)
5. Configure user access and permissions as needed

After completing these steps, you can test the connection from another Mac." buttons {"OK"} default button "OK" with title "Remote Desktop Manual Setup" with icon caution
EOF
    log "Manual setup dialog completed"
    return 0
  else
    log "User cancelled manual setup dialog"
    return 1
  fi
}

# Verify Remote Desktop functionality with accurate detection
verify_remote_desktop() {
  log "Verifying Remote Desktop status with accurate detection..."

  # Get accurate status for both services
  local screen_result rm_result
  screen_result=$(check_screen_sharing_status)
  rm_result=$(check_remote_management_status)

  local screen_status="${screen_result%|*}"
  local screen_details="${screen_result#*|}"
  local rm_status="${rm_result%|*}"
  local rm_details="${rm_result#*|}"

  # Report Screen Sharing status
  if [[ "${screen_status}" == "active" ]]; then
    log "✅ Screen Sharing is ACTIVE - ${screen_details}"
  else
    log "❌ Screen Sharing is INACTIVE - ${screen_details}"
  fi

  # Report Remote Management status
  if [[ "${rm_status}" == "active" ]]; then
    log "✅ Remote Management is ACTIVE - ${rm_details}"
  else
    log "❌ Remote Management is INACTIVE - ${rm_details}"
  fi

  # Determine overall status and provide appropriate feedback
  local setup_success=true
  local hostname
  hostname=$(hostname)

  log ""
  log "========================================="
  log "         VERIFICATION RESULTS"
  log "========================================="
  log ""

  if [[ "${screen_status}" == "active" ]] && [[ "${rm_status}" == "active" ]]; then
    log "🎯 SUCCESS: Both Screen Sharing and Remote Management are active"
    log "   Remote Desktop is fully functional with all features"
  elif [[ "${rm_status}" == "active" ]]; then
    log "🎯 SUCCESS: Remote Management is active"
    log "   Remote Management provides both Screen Sharing and ARD functionality"
  elif [[ "${screen_status}" == "active" ]]; then
    log "📺 PARTIAL: Screen Sharing is active, Remote Management is not"
    log "   Screen Sharing access available, but Apple Remote Desktop features not available"
  elif [[ "${screen_status}" == "partial" ]]; then
    log "⚠️  INCOMPLETE: Screen Sharing service loaded but agent not running"
    log "   This indicates setup is incomplete and needs manual configuration"
    setup_success=false
  else
    log "❌ FAILED: Neither Screen Sharing nor Remote Management is active"
    log "   Remote Desktop is not functional"
    setup_success=false
  fi

  # Show connection information if Screen Sharing or Remote Management works
  if [[ "${screen_status}" == "active" ]] || [[ "${rm_status}" == "active" ]]; then
    log ""
    log "========================================="
    log "        CONNECTION INFORMATION"
    log "========================================="
    log ""
    log "You can connect using:"
    log ""
    log "• Screen Sharing: Finder > Go > Connect to Server > ${hostname}.local"
    if [[ "${rm_status}" == "active" ]]; then
      log "• Apple Remote Desktop: Full ARD functionality available"
    else
      log "• Apple Remote Desktop: Not available (Remote Management not active)"
    fi
    log ""
    log "Test your connection from another Mac to verify setup is working."
  fi

  # Show manual setup dialog if setup was not successful
  if [[ "${setup_success}" != "true" ]]; then
    log ""
    log "Setup was not fully successful - showing manual setup instructions"
    show_manual_setup_dialog

    # Check status again after user completes manual setup
    log ""
    log "Re-checking status after manual setup opportunity..."
    screen_result=$(check_screen_sharing_status)
    rm_result=$(check_remote_management_status)

    screen_status="${screen_result%|*}"
    rm_status="${rm_result%|*}"

    if [[ "${screen_status}" == "active" ]] && [[ "${rm_status}" == "active" ]]; then
      log "✅ Both Screen Sharing and Remote Management are now active"
    elif [[ "${screen_status}" == "active" ]] || [[ "${rm_status}" == "active" ]]; then
      log "✅ Remote Desktop functionality is now available"
    else
      log "⚠️  Services still not active - manual setup may be needed"
      log "   This is not necessarily an error if you prefer to configure later"
    fi
  fi
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
