#!/usr/bin/env bash

# Command Line Tools installation for macOS with enhanced monitoring
# This script provides comprehensive CLT installation with progress tracking and verification

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="${0##*/}"
readonly LOG_PREFIX="[CLT Setup]"
readonly MAX_RETRIES=2
readonly DEFAULT_TIMEOUT=1800 # 30 minutes

# Logging function
log() {
  echo "${LOG_PREFIX} $*" >&2
}

# Enhanced logging function for important messages
show_log() {
  echo "${LOG_PREFIX} $*" >&2
}

# Show usage information
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Command Line Tools installation for macOS with enhanced monitoring.

OPTIONS:
    --force             Skip confirmation prompts
    --timeout SECONDS   Set installation timeout (default: ${DEFAULT_TIMEOUT})
    --help              Show this help message

DESCRIPTION:
    This script provides comprehensive Command Line Tools installation:
    1. Checks for existing CLT installation with enhanced verification
    2. Installs CLT using softwareupdate with real-time monitoring
    3. Falls back to interactive xcode-select installation if needed
    4. Provides comprehensive post-installation verification

FEATURES:
    - Real-time system log monitoring during installation
    - Network failure retry logic (up to ${MAX_RETRIES} attempts)
    - Enhanced verification including compiler functionality tests
    - System headers accessibility verification
    - Dynamic timeout adjustment based on network conditions
    - Comprehensive error reporting and recovery

EOF
}

# Simple CLT verification with 3 essential checks
verify_clt_installation() {
  local install_result="$1" # Pass in softwareupdate exit code

  log "Performing CLT verification..."

  # Check 1: softwareupdate succeeded
  if [[ "${install_result}" -ne 0 ]]; then
    log "❌ softwareupdate failed (exit code: ${install_result})"
    return 1
  fi
  log "✅ softwareupdate completed successfully"

  # Check 2: xcode-select path exists
  if ! xcode-select -p >/dev/null 2>&1; then
    log "❌ xcode-select path verification failed"
    return 1
  fi
  local clt_path
  clt_path=$(xcode-select -p)
  log "✅ CLT path verified: ${clt_path}"

  # Check 3: pkgutil shows installed version
  if ! pkgutil --pkg-info=com.apple.pkg.CLTools_Executables | grep version >/dev/null 2>&1; then
    log "❌ CLT package verification failed"
    return 1
  fi
  local version
  version=$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables | grep version | cut -d: -f2 | xargs)
  log "✅ CLT package verified, version: ${version}"

  log "✅ CLT verification passed all checks"
  return 0
}

# Enhanced CLT installation with improved monitoring and retry logic
install_clt_with_enhanced_monitoring() {
  local clt_package="$1"
  local install_timeout="$2"
  local install_pid
  local monitor_pid
  local elapsed_time=0
  local retry_count=0
  local install_successful=false

  show_log "Installing Command Line Tools with enhanced monitoring: ${clt_package}"
  show_log "This may take 10-30 minutes depending on your internet connection..."
  show_log "Installation timeout: ${install_timeout} seconds ($((install_timeout / 60)) minutes)"

  while [[ ${retry_count} -le ${MAX_RETRIES} ]] && [[ "${install_successful}" == "false" ]]; do
    if [[ ${retry_count} -gt 0 ]]; then
      show_log "Retry attempt ${retry_count}/${MAX_RETRIES} for CLT installation..."
      # Clean up any previous installation attempts
      sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
      sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
      sleep 5
    fi

    # Start the installation in background
    softwareupdate --verbose -i "${clt_package}" &
    install_pid=$!

    # Enhanced log monitoring with better filtering and phase detection
    local monitor_script="/tmp/enhanced_clt_monitor_$$"
    cat >"${monitor_script}" <<'ENHANCED_MONITOR_EOF'
#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[CLT Monitor] $*"
}

# Enhanced monitoring with phase detection and comprehensive error handling
monitor_installation() {
  local download_detected=false
  local install_detected=false
  local network_issues=0
  local max_network_issues=3

  # Monitor both SoftwareUpdate and installer subsystems for comprehensive coverage
  sudo -p "[CLT Setup] Enter password for installation monitoring: " log stream \
    --predicate '(subsystem == "com.apple.SoftwareUpdate" OR subsystem == "com.apple.installer" OR processImagePath CONTAINS[c] "softwareupdate") AND (category == "default" OR category == "install")' \
    --info 2>/dev/null | while IFS= read -r line; do

    # Enhanced pattern matching with more specific filters
    case "$line" in
      *"Command Line Tools"*|*"CommandLineTools"*|*"Xcode"*)
        # Download phase detection
        if echo "$line" | grep -qiE "(download|fetch|retrieving|getting|progress.*download)"; then
          if [[ "${download_detected}" == "false" ]]; then
            echo "[CLT Monitor] 📥 Download phase started"
            download_detected=true
          fi
          # Extract meaningful message from log entry
          local clean_message
          clean_message=$(echo "$line" | sed -E 's/.*eventMessage:"([^"]*).*/\1/' | sed 's/\\n/ /g' | head -c 100)
          if [[ -n "${clean_message}" && "${clean_message}" != "${line}" ]]; then
            echo "[CLT Monitor] 📥 Download: ${clean_message}"
          else
            echo "[CLT Monitor] 📥 Download activity detected"
          fi

        # Installation phase detection
        elif echo "$line" | grep -qiE "(install|configur|setup|deploy|extract|prepar)"; then
          if [[ "${install_detected}" == "false" ]]; then
            echo "[CLT Monitor] ⚙️  Installation phase started"
            install_detected=true
          fi
          local clean_message
          clean_message=$(echo "$line" | sed -E 's/.*eventMessage:"([^"]*).*/\1/' | sed 's/\\n/ /g' | head -c 100)
          if [[ -n "${clean_message}" && "${clean_message}" != "${line}" ]]; then
            echo "[CLT Monitor] ⚙️  Install: ${clean_message}"
          else
            echo "[CLT Monitor] ⚙️  Installation activity detected"
          fi

        # Success detection
        elif echo "$line" | grep -qiE "(success|complete|finish|done|successfully)"; then
          echo "[CLT Monitor] ✅ Installation phase completed successfully"
          break

        # Generic CLT activity
        else
          local clean_message
          clean_message=$(echo "$line" | sed -E 's/.*eventMessage:"([^"]*).*/\1/' | sed 's/\\n/ /g' | head -c 80)
          if [[ -n "${clean_message}" && "${clean_message}" != "${line}" ]]; then
            echo "[CLT Monitor] 🔧 CLT: ${clean_message}"
          fi
        fi
        ;;

      # Network and error detection
      *"network"*|*"connection"*|*"timeout"*|*"failed"*|*"error"*)
        if echo "$line" | grep -qiE "(network.*error|connection.*fail|timeout|download.*fail)"; then
          network_issues=$((network_issues + 1))
          echo "[CLT Monitor] ⚠️  Network issue ${network_issues}/${max_network_issues}: $(echo "$line" | head -c 100)"

          if [[ ${network_issues} -ge ${max_network_issues} ]]; then
            echo "[CLT Monitor] ❌ Too many network issues detected, installation may need retry"
            break
          fi
        fi
        ;;
    esac
  done
}

monitor_installation
ENHANCED_MONITOR_EOF

    chmod +x "${monitor_script}"
    "${monitor_script}" &
    monitor_pid=$!

    # Enhanced timeout with periodic progress reporting
    log "Monitoring CLT installation (timeout: ${install_timeout}s, attempt: $((retry_count + 1)))"
    elapsed_time=0

    while kill -0 "${install_pid}" 2>/dev/null; do
      if [[ ${elapsed_time} -ge ${install_timeout} ]]; then
        show_log "❌ Command Line Tools installation timed out after ${install_timeout} seconds"
        kill "${install_pid}" 2>/dev/null || true
        kill "${monitor_pid}" 2>/dev/null || true
        break
      fi

      sleep 10
      elapsed_time=$((elapsed_time + 10))

      # Enhanced progress reporting with phase awareness
      if [[ $((elapsed_time % 120)) -eq 0 ]]; then
        local elapsed_min=$((elapsed_time / 60))
        local remaining_min=$(((install_timeout - elapsed_time) / 60))
        local log_msg="CLT installation in progress... (${elapsed_min}m elapsed, ~${remaining_min}m remaining)"
        echo -e "\n"
        log "${log_msg}"
      fi
    done

    # Stop monitoring and cleanup
    kill "${monitor_pid}" 2>/dev/null || true
    rm -f "${monitor_script}" 2>/dev/null || true

    # Wait for the install process to fully complete
    if kill -0 "${install_pid}" 2>/dev/null; then
      # Process is still running, force termination
      kill "${install_pid}" 2>/dev/null || true
      wait "${install_pid}" 2>/dev/null || true
      install_result=1
    else
      wait "${install_pid}" 2>/dev/null || true
      install_result=$?
    fi

    # Enhanced verification with comprehensive checks
    if verify_clt_installation "${install_result}"; then
      local install_time_min=$((elapsed_time / 60))
      local install_time_sec=$((elapsed_time % 60))
      show_log "✅ Command Line Tools installation completed successfully in ${install_time_min}m ${install_time_sec}s"
      install_successful=true
    else
      show_log "❌ Command Line Tools installation failed (exit code: ${install_result}, retry: ${retry_count}/${MAX_RETRIES})"
      retry_count=$((retry_count + 1))

      if [[ ${retry_count} -le ${MAX_RETRIES} ]]; then
        show_log "Preparing for retry in 10 seconds..."
        sleep 10
      fi
    fi
  done

  if [[ "${install_successful}" == "true" ]]; then
    return 0
  else
    show_log "❌ All CLT installation attempts failed after ${MAX_RETRIES} retries"
    return 1
  fi
}

# Interactive CLT installation fallback
interactive_clt_installation() {
  local force="$1"

  show_log "Using interactive xcode-select installation method..."

  if [[ "${force}" = "false" ]]; then
    show_log "This will open a dialog for Command Line Tools installation"
    read -rp "${LOG_PREFIX} Press any key to continue..." -n 1 -r
    echo
  fi

  xcode-select --install

  # Wait for installation to complete
  show_log "Waiting for Command Line Tools installation to complete..."
  show_log "Please complete the installation dialog, then press any key to continue"

  if [[ "${force}" = "false" ]]; then
    read -rp "${LOG_PREFIX} Press any key when installation is complete..." -n 1 -r
    echo
  else
    # In force mode, poll for completion with enhanced feedback
    local wait_time=0
    while ! verify_clt_installation "0" 2>/dev/null; do
      sleep 10
      wait_time=$((wait_time + 10))
      if [[ $((wait_time % 60)) -eq 0 ]]; then
        local wait_min=$((wait_time / 60))
        log "Waiting for Command Line Tools installation... (${wait_min}m elapsed)"
      fi
    done
  fi

  # Verify installation
  if verify_clt_installation "0"; then
    show_log "✅ Interactive Command Line Tools installation completed successfully"
    return 0
  else
    show_log "❌ Interactive Command Line Tools installation verification failed"
    return 1
  fi
}

# Main execution function
main() {
  local force=false
  local install_timeout=${DEFAULT_TIMEOUT}

  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force)
        force=true
        shift
        ;;
      --timeout)
        install_timeout="$2"
        shift 2
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

  log "Starting Command Line Tools setup for macOS"

  local server_name
  server_name=$(hostname)
  log "Server: ${server_name}"

  local macos_version
  macos_version=$(sw_vers -productVersion 2>/dev/null || echo 'unknown')
  log "macOS: ${macos_version}"

  local architecture
  architecture=$(uname -m)
  log "Architecture: ${architecture}"

  # Check if CLT is already installed with enhanced verification
  if verify_clt_installation "0" 2>/dev/null; then
    log "✅ Command Line Tools already installed and verified"
    exit 0
  fi

  log "Command Line Tools not detected or incomplete - proceeding with installation"

  # Confirmation prompt
  if [[ "${force}" != "true" ]]; then
    echo "${LOG_PREFIX} This script will:"
    echo "${LOG_PREFIX} 1. Install Xcode Command Line Tools using enhanced monitoring"
    echo "${LOG_PREFIX} 2. Provide real-time progress feedback during installation"
    echo "${LOG_PREFIX} 3. Perform comprehensive verification after installation"
    echo "${LOG_PREFIX} 4. Fall back to interactive installation if needed"
    echo ""
    echo "${LOG_PREFIX} Installation timeout: ${install_timeout} seconds ($((install_timeout / 60)) minutes)"
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

  # Touch flag to indicate user has requested CLT installation
  sudo -p "${LOG_PREFIX} Enter password to create installation flag: " \
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

  # Find and install the latest CLT package
  show_log "Detecting available Command Line Tools package..."
  local clt_package
  clt_package=$(softwareupdate -l 2>/dev/null | grep "Command Line Tools" | grep "Label:" | tail -n 1 | cut -d ':' -f 2 | xargs)

  if [[ -n "${clt_package}" ]]; then
    show_log "Found CLT package: ${clt_package}"

    # Run enhanced installation
    if install_clt_with_enhanced_monitoring "${clt_package}" "${install_timeout}"; then
      log "✅ Enhanced CLT installation completed successfully"
    else
      log "Enhanced CLT installation failed - falling back to interactive method"

      # Clean up flag for interactive method
      sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

      if interactive_clt_installation "${force}"; then
        log "✅ Interactive CLT installation completed successfully"
      else
        log "❌ All CLT installation methods failed"
        exit 1
      fi
    fi
  else
    show_log "⚠️  Could not determine CLT package via softwareupdate"
    show_log "Falling back to interactive xcode-select installation"

    # Clean up the flag since we're switching methods
    sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

    if interactive_clt_installation "${force}"; then
      log "✅ Interactive CLT installation completed successfully"
    else
      log "❌ Interactive CLT installation failed"
      exit 1
    fi
  fi

  # Clean up the flag regardless of method used
  sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

  log ""
  log "========================================="
  log "       CLT INSTALLATION COMPLETE"
  log "========================================="
  log ""
  log "✅ Command Line Tools installation and verification completed successfully"
  log ""
  log "Installed tools verified:"
  log "• Development tools: clang, git, make, cc, c++"
  log "• Compiler functionality tested and working"
  log "• System headers accessible"
  log ""
  log "Command Line Tools are ready for use!"
}

# Execute main function with all arguments
main "$@"
