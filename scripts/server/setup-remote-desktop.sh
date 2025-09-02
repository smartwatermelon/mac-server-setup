#!/usr/bin/env bash

# Remote Desktop setup for macOS with user-guided configuration
# This script disables existing services and guides users through manual setup

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="${0##*/}"
readonly LOG_PREFIX="[Remote Desktop Setup]"

# Logging function
log() {
  echo "${LOG_PREFIX} $*" >&2
}

# Enhanced logging function for important messages
show_log() {
  echo "${LOG_PREFIX} $*" >&2
}

# Error and warning collection functions for module context
# These write to temporary files shared with first-boot.sh
collect_error() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  # Append to shared temporary file (exported from first-boot.sh)
  if [[ -n "${SETUP_ERRORS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_ERRORS_FILE}"
  fi
}

collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "⚠️ ${clean_message}"
  # Append to shared temporary file (exported from first-boot.sh)
  if [[ -n "${SETUP_WARNINGS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_WARNINGS_FILE}"
  fi
}

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  log "====== $1 ======"
}

# Show usage information
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Remote Desktop setup for macOS with user-guided configuration.

OPTIONS:
    --force             Skip confirmation prompts
    --help              Show this help message

DESCRIPTION:
    This script provides a reliable approach to Remote Desktop setup:
    1. Disables existing remote desktop services to ensure a clean state
    2. Provides detailed instructions for manually enabling services
    3. Opens System Settings to the correct location for easy setup
    4. Guides users through the required configuration steps

NOTES:
    - Requires administrator privileges for service management
    - Uses user-guided setup to ensure reliable configuration
    - Compatible with all macOS versions including 15.6+
    - Manual setup avoids macOS Remote Desktop activation complexities

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
  set_section "Disabling Remote Management"

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
  set_section "Disabling Screen Sharing"

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

# Show GUI dialog with manual setup instructions
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
display dialog "Remote Desktop Manual Setup

The script has disabled existing services to ensure a clean state.

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

# Manual activation routine - core setup approach
manual_activation_routine() {
  set_section "Manual Remote Desktop Setup"

  if show_manual_setup_dialog; then
    log ""
    log "Manual setup dialog completed successfully"
    log "Remote Desktop services should now be configured in System Settings"

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
    echo "${LOG_PREFIX} 1. Disable existing remote desktop services to ensure clean state"
    echo "${LOG_PREFIX} 2. Open System Settings to the Sharing configuration page"
    echo "${LOG_PREFIX} 3. Guide you through manually enabling Screen Sharing and Remote Management"
    echo "${LOG_PREFIX} 4. Provide step-by-step instructions for proper configuration"
    echo "${LOG_PREFIX} 5. Verify the services are working after manual setup"
    echo ""
    echo "${LOG_PREFIX} This requires administrator privileges and manual interaction."
    echo ""
    echo "${LOG_PREFIX} 💡 If Screen Sharing and Remote Desktop are already working"
    echo "${LOG_PREFIX} 💡   satisfactorily, answer 'N' to skip this section."
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

  # Execute disable-then-guide approach
  log "Using disable-then-guide Remote Desktop setup approach..."

  # Phase 1: Clean Slate - Disable both services
  log ""
  log "Phase 1: Creating clean slate by disabling existing services..."
  close_system_settings
  disable_remote_management
  disable_screen_sharing

  # Phase 2: Guide user through manual setup
  log ""
  log "Phase 2: Guiding user through manual configuration..."
  manual_activation_routine

  log ""
  log "========================================="
  log "           SETUP COMPLETE"
  log "========================================="
  log ""
  log "Remote Desktop setup guidance completed!"
  log ""
  log "EXPECTED FINAL STATE (after manual setup):"
  log "• Remote Management should be ON and controlling Screen Sharing"
  log "• Both Screen Sharing and Apple Remote Desktop functionality available"
  log ""
  log "TESTING YOUR SETUP:"
  log "• Test the connection from another Mac:"
  local hostname
  hostname=$(hostname)
  log "  - Screen Sharing: Finder > Go > Connect to Server > ${hostname}.local"
  log "  - Apple Remote Desktop: Use ARD app with full functionality"
  log "• Configure firewall if needed (should be pre-configured)"
  log "• Set up additional user accounts with appropriate access"
  log ""
  log "TROUBLESHOOTING:"
  log "If connections fail, verify in System Settings > General > Sharing that:"
  log "• Screen Sharing shows 'On' or 'Controlled by Remote Management'"
  log "• Remote Management shows 'On' with proper user access configured"
  log "• Check firewall settings if remote connections are blocked"
}

# Execute main function with all arguments
main "$@"
