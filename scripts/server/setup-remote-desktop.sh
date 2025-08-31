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

# Close System Settings if it's open
close_system_settings() {
  log "Pre-step: Closing System Settings if open..."
  osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true
  log "System Settings closed (or wasn't running)"
}

# Disable Remote Management with verification
disable_remote_management() {
  log "Disabling Remote Management..."

  # Method 1: kickstart deactivate
  log "Method 1: Using kickstart -deactivate -stop"
  sudo -p "${LOG_PREFIX} Enter password to disable Remote Management: " \
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -deactivate -stop 2>/dev/null || log "kickstart -deactivate failed (expected)"

  # Method 2: kickstart uninstall settings
  log "Method 2: Using kickstart -uninstall -settings"
  sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -uninstall -settings 2>/dev/null || log "kickstart -uninstall failed (expected)"

  # Method 3: Kill ARDAgent processes
  log "Method 3: Killing ARDAgent processes"
  sudo pkill -f "ARDAgent" 2>/dev/null || log "No ARDAgent processes to kill"

  # Method 4: Kill RemoteManagement processes
  log "Method 4: Killing RemoteManagement processes"
  sudo pkill -f "RemoteManagement" 2>/dev/null || log "No RemoteManagement processes to kill"

  # Verify Remote Management is off
  log ""
  log "Verifying Remote Management is off..."
  if pgrep -f "ARDAgent" >/dev/null 2>&1; then
    log "⚠️  ARDAgent processes still running"
    pgrep -fl "ARDAgent"
  else
    log "✅ No ARDAgent processes running"
  fi

  if launchctl list | grep -q "RemoteManagementAgent"; then
    log "⚠️  RemoteManagementAgent service still loaded"
  else
    log "✅ No RemoteManagementAgent service loaded"
  fi
}

# Disable Screen Sharing with verification
disable_screen_sharing() {
  log "Disabling Screen Sharing..."

  # Method 1: launchctl unload
  log "Method 1: Using launchctl unload"
  sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || log "launchctl unload failed (expected)"

  # Method 2: Remove overrides.plist entry
  log "Method 2: Removing overrides.plist entry"
  sudo defaults delete /var/db/launchd.db/com.apple.launchd/overrides.plist com.apple.screensharing 2>/dev/null || log "overrides.plist delete failed (expected)"

  # Method 3: Kill screensharing processes
  log "Method 3: Killing screensharing processes"
  sudo pkill -f "screensharing" 2>/dev/null || log "No screensharing processes to kill"

  # Method 4: Kill Screen Sharing agents
  log "Method 4: Killing Screen Sharing agent processes"
  sudo pkill -f "ScreensharingAgent" 2>/dev/null || log "No ScreensharingAgent processes to kill"

  # Verify Screen Sharing is off
  log ""
  log "Verifying Screen Sharing is off..."
  if launchctl list | grep -q "screensharing"; then
    log "⚠️  Screen sharing services still loaded:"
    launchctl list | grep screensharing
  else
    log "✅ No screen sharing services loaded"
  fi

  if pgrep -f "screensharing" >/dev/null 2>&1; then
    log "⚠️  Screen sharing processes still running"
    pgrep -fl "screensharing"
  else
    log "✅ No screen sharing processes running"
  fi
}

# Enable Remote Management with verification
enable_remote_management() {
  log "Enabling Remote Management..."

  # Capture kickstart output with verbose flag
  local kickstart_output
  kickstart_output=$(sudo -p "${LOG_PREFIX} Enter password to configure Remote Management: " \
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -users admin -privs -all -restart -agent -menu -verbose 2>&1) || {
    log "WARNING: kickstart command failed"
    log "Output: ${kickstart_output}"
    return 1
  }

  # Wait for service to start
  sleep 3

  # Verify Remote Management is active
  local rm_result
  rm_result=$(check_remote_management_status)
  local rm_status="${rm_result%|*}"
  local rm_details="${rm_result#*|}"

  if [[ "${rm_status}" == "active" ]]; then
    log "✅ Remote Management activated successfully - ${rm_details}"
    log "Kickstart output: ${kickstart_output}"
    return 0
  else
    log "❌ Remote Management activation failed - ${rm_details}"
    log "Kickstart output: ${kickstart_output}"
    return 1
  fi
}

# Enable Screen Sharing with verification
enable_screen_sharing() {
  log "Enabling Screen Sharing..."

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

  # Wait for service to start
  sleep 3

  # Verify Screen Sharing is active
  local screen_result
  screen_result=$(check_screen_sharing_status)
  local screen_status="${screen_result%|*}"
  local screen_details="${screen_result#*|}"

  if [[ "${screen_status}" == "active" ]]; then
    log "✅ Screen Sharing activated successfully - ${screen_details}"
    return 0
  else
    log "❌ Screen Sharing activation failed - ${screen_details}"
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

  # Check for dedicated Screen Sharing agent service (correct service name from diagnostics)
  if launchctl list | grep -q com.apple.screensharing.agent; then
    status="active"
    details="Screen Sharing agent service active"
  # Check if Screen Sharing is available through overrides.plist (fallback method)
  elif sudo test -f "/var/db/launchd.db/com.apple.launchd/overrides.plist"; then
    local screen_override
    screen_override=$(sudo defaults read "/var/db/launchd.db/com.apple.launchd/overrides.plist" com.apple.screensharing 2>/dev/null || echo "not found")
    if [[ "${screen_override}" == *"Disabled = 0"* ]]; then
      status="active"
      details="Screen Sharing enabled via overrides.plist"
    else
      details="Screen Sharing not enabled in overrides.plist"
    fi
  else
    details="no Screen Sharing service detected"
  fi

  echo "${status}|${details}"
}

# Function to check Remote Management status accurately
check_remote_management_status() {
  local status="inactive"
  local details=""

  # Check for Remote Management agent service (from diagnostics)
  if launchctl list | grep -q com.apple.RemoteManagementAgent; then
    status="active"
    details="Remote Management agent service active"
  # Fallback: Check ARDAgent process
  elif pgrep -f "/System/Library/CoreServices/RemoteManagement/ARDAgent" >/dev/null 2>&1; then
    status="active"
    details="ARDAgent process running"
  else
    details="Remote Management not active"
  fi

  echo "${status}|${details}"
}

# Show GUI dialog with manual instructions when auto-activation fails
show_manual_setup_dialog() {
  log "Showing manual setup instructions dialog..."

  # Open System Settings to the Sharing page first
  log "Opening System Settings to Sharing page..."
  if open "x-apple.systempreferences:com.apple.preferences.sharing"; then
    log "System Settings opened to Sharing page"
  else
    log "WARNING: Could not open System Settings automatically"
  fi

  # Give System Settings time to load
  sleep 2

  if osascript <<'EOF'; then
display dialog "Remote Desktop Setup Incomplete

Automatic setup was unable to fully activate Remote Desktop services.

System Settings has been opened to the Sharing page for you.

Please complete the setup manually:

1. Click the ℹ️ button next to the Screen Sharing toggle.
2. Turn ON 'Screen Sharing' from the Screen Sharing pop-up.
3. Click Done.
4. Click the ℹ️ button next to the Remote Management toggle.
5. Turn ON 'Remote Management' from the Remote Management pop-up.
6. Click Options.
7. Turn on at least 'Observe' and 'Control', and click OK.
8. Click Done.

After completing these steps, click OK to re-test the configuration." buttons {"OK"} default button "OK" with title "Remote Desktop Manual Setup" with icon caution
EOF
    log "Manual setup dialog completed"
    return 0
  else
    log "User cancelled manual setup dialog"
    return 1
  fi
}

# Manual activation routine when automatic setup fails
manual_activation_routine() {
  log "Running manual activation routine..."

  if show_manual_setup_dialog; then
    # After manual setup, only test Remote Management
    # (Screen Sharing tests are unreliable when controlled by Remote Management)
    log ""
    log "Re-checking Remote Management status after manual setup..."

    local post_manual_rm_result
    post_manual_rm_result=$(check_remote_management_status)
    local post_manual_rm_status="${post_manual_rm_result%|*}"
    local post_manual_rm_details="${post_manual_rm_result#*|}"

    if [[ "${post_manual_rm_status}" == "active" ]]; then
      log "✅ Manual setup successful - Remote Management is active"
      log "Details: ${post_manual_rm_details}"
    else
      log "⚠️  Remote Management still not detected as active after manual setup"
      log "Details: ${post_manual_rm_details}"
      log "If Screen Sharing and Remote Management show as ON in System Settings,"
      log "then the services are working despite detection issues"
    fi

    # Close System Settings
    log "Closing System Settings..."
    osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true
  else
    log "Manual setup was cancelled - continuing without Remote Desktop"
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

  # Execute correct activation sequence
  log "Using correct Remote Desktop activation sequence..."

  # Phase 1: Clean Slate - Disable both services
  log ""
  log "Phase 1: Creating clean slate..."
  close_system_settings
  disable_remote_management
  disable_screen_sharing
  local activation_success=false

  #   # Phase 2: Sequential Activation - Screen Sharing first, then Remote Management
  #   log ""
  #   log "Phase 2: Sequential activation..."
  #
  #   local activation_success=true
  #
  #   # Step 1: Enable Screen Sharing
  #   if enable_screen_sharing; then
  #     log "Screen Sharing activation successful, proceeding to Remote Management"
  #
  #     # Step 2: Enable Remote Management
  #     if enable_remote_management; then
  #       log "Remote Management activation successful"
  #       log "🎯 Automatic activation sequence completed successfully"
  #     else
  #       log "Remote Management activation failed - jumping to manual setup"
  #       activation_success=false
  #     fi
  #   else
  #     log "Screen Sharing activation failed - jumping to manual setup"
  #     activation_success=false
  #   fi
  #
  #   # Phase 3: Handle manual setup if needed, then verify final state
  #   if [[ "${activation_success}" == "true" ]]; then
  #     log ""
  #     log "Phase 3: Verifying final state..."
  #     log "Note: Only checking Remote Management (now controls Screen Sharing)"
  #
  #     local final_rm_result
  #     final_rm_result=$(check_remote_management_status)
  #     local final_rm_status="${final_rm_result%|*}"
  #     local final_rm_details="${final_rm_result#*|}"
  #
  #     if [[ "${final_rm_status}" == "active" ]]; then
  #       log "✅ Final verification: Remote Management active and controlling Screen Sharing"
  #       log "Details: ${final_rm_details}"
  #     else
  #       log "❌ Final verification failed: Remote Management not active"
  #       activation_success=false
  #     fi
  #   fi

  # If activation failed at any point, run manual setup
  if [[ "${activation_success}" != "true" ]]; then
    log ""
    log "Automatic activation failed - showing manual setup dialog"
    manual_activation_routine
  fi

  log ""
  log "========================================="
  log "           SETUP COMPLETE"
  log "========================================="
  log ""
  log "Remote Desktop setup process completed!"
  log ""
  log "FINAL STATE:"
  log "• Remote Management should be active and controlling Screen Sharing"
  log "• Both Screen Sharing and Apple Remote Desktop functionality available"
  log ""
  log "NEXT STEPS:"
  log "• Test the connection from another Mac:"
  local hostname
  hostname=$(hostname)
  log "  - Screen Sharing: Finder > Go > Connect to Server > ${hostname}.local"
  log "  - Apple Remote Desktop: Use ARD app with full functionality"
  log "• Configure firewall if needed (should be pre-configured)"
  log "• Set up additional user accounts with appropriate access"
  log ""
  log "If connections fail, verify in System Settings > General > Sharing that:"
  log "• Screen Sharing shows 'On' or 'Controlled by Remote Management'"
  log "• Remote Management shows 'On'"
}

# Execute main function with all arguments
main "$@"
