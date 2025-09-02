#!/usr/bin/env bash
#
# setup-homebrew-packages.sh - Homebrew and package installation module
#
# This script installs and configures Homebrew and packages from configuration files.
# It handles Xcode Command Line Tools, Homebrew installation, package management,
# and post-installation optimization.
#
# Usage: ./setup-homebrew-packages.sh [--force] [--skip-homebrew] [--skip-packages]
#   --force: Skip all confirmation prompts
#   --skip-homebrew: Skip Homebrew installation/update
#   --skip-packages: Skip package installation
#
# Author: Claude (modularized from first-boot.sh)
# Version: 1.0
# Created: 2025-09-02

# Exit on any error
set -euo pipefail

# Parse command line arguments
FORCE=false
SKIP_HOMEBREW=false
SKIP_PACKAGES=false

for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    --skip-homebrew)
      SKIP_HOMEBREW=true
      shift
      ;;
    --skip-packages)
      SKIP_PACKAGES=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Set up logging
export LOG_DIR
LOG_DIR="${HOME}/.local/state" # XDG_STATE_HOME
current_hostname="$(hostname)"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${current_hostname}")"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# log function - only writes to log file
log() {
  mkdir -p "${LOG_DIR}"
  local timestamp no_newline=false
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  # Check for -n flag
  if [[ "$1" == "-n" ]]; then
    no_newline=true
    shift
  fi

  if [[ "${no_newline}" == true ]]; then
    echo -n "[${timestamp}] $1" >>"${LOG_FILE}"
  else
    echo "[${timestamp}] $1" >>"${LOG_FILE}"
  fi
}

# show_log function - shows output to user and logs
show_log() {
  echo "$1"
  log "$1"
}

# section function - shows section header and logs
section() {
  show_log ""
  show_log "=== $1 ==="
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

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  show_log ""
  show_log "=== $1 ==="
}

# check_success function
check_success() {
  local operation_name="$1"
  local exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    log "✅ ${operation_name}"
  else
    if [[ "${FORCE}" == true ]]; then
      collect_warning "${operation_name} failed but continuing due to --force flag"
    else
      collect_error "${operation_name} failed"
      show_log "❌ ${operation_name} failed (exit code: ${exit_code})"
      read -p "Continue anyway? (y/N): " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Configuration variables
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"
FORMULAE_FILE="${SETUP_DIR}/config/formulae.txt"
CASKS_FILE="${SETUP_DIR}/config/casks.txt"

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  log "Loaded configuration from ${CONFIG_FILE}"
else
  echo "Warning: Configuration file not found at ${CONFIG_FILE}"
  echo "Using default values - you may want to create config.conf"
fi

# Set derived variables
ADMIN_USERNAME=$(whoami)
HOMEBREW_PREFIX="/opt/homebrew" # Apple Silicon

#
# HOMEBREW & PACKAGE INSTALLATION
#
# Install Xcode Command Line Tools using dedicated script
set_section "Installing Xcode Command Line Tools"

# Use the dedicated CLT installation script with enhanced monitoring
clt_script="${SETUP_DIR}/scripts/setup-command-line-tools.sh"

if [[ -f "${clt_script}" ]]; then
  log "Using enhanced Command Line Tools installation script..."

  # Prepare CLT installation arguments
  clt_args=()
  if [[ "${FORCE}" == true ]]; then
    clt_args+=(--force)
  fi

  # Run the dedicated CLT installation script
  if "${clt_script}" ${clt_args[@]+"${clt_args[@]}"}; then
    log "✅ Command Line Tools installation completed successfully"
  else
    collect_error "Command Line Tools installation failed"
    exit 1
  fi
else
  collect_error "CLT installation script not found: ${clt_script}"
  log "Please ensure setup-command-line-tools.sh is present in the scripts directory"
  exit 1
fi

# Install Homebrew
if [[ "${SKIP_HOMEBREW}" == false ]]; then
  set_section "Installing Homebrew"

  # Check if Homebrew is already installed
  if command -v brew &>/dev/null; then
    BREW_VERSION=$(brew --version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "unknown")
    log "Homebrew is already installed (version ${BREW_VERSION})"

    # Update Homebrew if already installed
    log "Updating Homebrew"
    brew update
    check_success "Homebrew update"
    log "Updating installed packages"
    brew upgrade
    check_success "Homebrew package upgrade"
  else
    show_log "Installing Homebrew using official installation script"

    # Use the official Homebrew installation script
    HOMEBREW_INSTALLER=$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
    NONINTERACTIVE=1 /bin/bash -c "${HOMEBREW_INSTALLER}"
    check_success "Homebrew installation"

    # Follow Homebrew's suggested post-installation steps
    log "Running Homebrew's suggested post-installation steps"

    # Add to .zprofile (Homebrew's recommended approach)
    echo >>"/Users/${ADMIN_USERNAME}/.zprofile"
    echo "eval \"\$(${HOMEBREW_PREFIX}/bin/brew shellenv)\"" >>"/Users/${ADMIN_USERNAME}/.zprofile"
    log "Added Homebrew to .zprofile"

    # Apply to current session
    BREW_SHELLENV=$("${HOMEBREW_PREFIX}/bin/brew" shellenv)
    eval "${BREW_SHELLENV}"
    log "Applied Homebrew environment to current session"

    # Add to other shell configuration files for compatibility
    for SHELL_PROFILE in ~/.bash_profile ~/.profile; do
      if [[ -f "${SHELL_PROFILE}" ]]; then
        # Only add if not already present
        if ! grep -q "HOMEBREW_PREFIX\|brew shellenv" "${SHELL_PROFILE}"; then
          log "Adding Homebrew to ${SHELL_PROFILE}"
          echo -e '\n# Homebrew' >>"${SHELL_PROFILE}"
          echo "eval \"\$(${HOMEBREW_PREFIX}/bin/brew shellenv)\"" >>"${SHELL_PROFILE}"
        fi
      fi
    done

    show_log "Homebrew installation completed"

    # Verify installation with brew help
    if brew help >/dev/null 2>&1; then
      show_log "✅ Homebrew verification successful"
    else
      collect_error "Homebrew verification failed - brew help returned an error"
      exit 1
    fi
  fi
else
  echo "❌ Value of SKIP_HOMEBREW was ${SKIP_HOMEBREW}"
  exit 1
fi

# Add concurrent download configuration
section "Configuring Homebrew for Optimal Performance"
export HOMEBREW_DOWNLOAD_CONCURRENCY=auto
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo "2x")"
log "Enabled concurrent downloads (auto mode - using ${CORES} CPU cores for optimal parallelism)"

# Install packages
if [[ "${SKIP_PACKAGES}" == false ]]; then
  section "Installing Packages"

  # Function to install formulae if not already installed
  install_formula() {
    if ! brew list "$1" &>/dev/null; then
      log "Installing formula: $1"
      if brew install "$1"; then
        log "✅ Formula installation: $1"
      else
        collect_error "Formula installation failed: $1"
        # Continue instead of exiting
      fi
    else
      log "Formula already installed: $1"
    fi
  }

  # Function to install casks if not already installed
  install_cask() {
    if ! brew list --cask "$1" &>/dev/null; then
      log "Installing cask: $1"

      # Capture /Applications before installation
      local before_apps
      before_apps=$(find /Applications -maxdepth 1 -type d -name "*.app" 2>/dev/null | sort)

      if brew install --cask "$1"; then
        log "✅ Cask installation: $1"

        # Capture /Applications after installation
        local after_apps
        after_apps=$(find /Applications -maxdepth 1 -type d -name "*.app" 2>/dev/null | sort)

        # Find newly installed apps and remove quarantine attributes
        local new_apps
        new_apps=$(comm -13 <(echo "${before_apps}") <(echo "${after_apps}"))

        if [[ -n "${new_apps}" ]]; then
          while IFS= read -r app_path; do
            if [[ -n "${app_path}" ]]; then
              log "Removing quarantine attribute from: $(basename "${app_path}")"
              xattr -d com.apple.quarantine "${app_path}" 2>/dev/null || true
            fi
          done <<<"${new_apps}"
        fi
      else
        collect_error "Cask installation failed: $1"
        # Continue instead of exiting
      fi
    else
      log "Cask already installed: $1"
    fi
  }

  # Install formulae from list
  if [[ -f "${FORMULAE_FILE}" ]]; then
    show_log "Installing formulae from ${FORMULAE_FILE}"
    formulae=()
    if [[ -f "${FORMULAE_FILE}" ]]; then
      while IFS= read -r line; do
        if [[ -n "${line}" && ! "${line}" =~ ^# ]]; then
          formulae+=("${line}")
        fi
      done <"${FORMULAE_FILE}"
    fi
    for formula in "${formulae[@]}"; do
      install_formula "${formula}"
    done
  else
    log "Formulae list not found, skipping formula installations"
  fi

  # Install casks from list
  if [[ -f "${CASKS_FILE}" ]]; then
    show_log "Installing casks from ${CASKS_FILE}"
    casks=()
    if [[ -f "${CASKS_FILE}" ]]; then
      while IFS= read -r line; do
        if [[ -n "${line}" && ! "${line}" =~ ^# ]]; then
          casks+=("${line}")
        fi
      done <"${CASKS_FILE}"
    fi
    for cask in "${casks[@]}"; do
      install_cask "${cask}"
    done
  else
    log "Casks list not found, skipping cask installations"
  fi

  # Cleanup after installation
  log "Cleaning up Homebrew files"
  brew cleanup
  check_success "Homebrew cleanup"

  # Run brew doctor and save output
  log "Running brew doctor diagnostic"
  BREW_DOCTOR_OUTPUT="${LOG_DIR}/brew-doctor-$(date +%Y%m%d-%H%M%S).log"
  brew doctor >"${BREW_DOCTOR_OUTPUT}" 2>&1 || true
  log "Brew doctor output saved to: ${BREW_DOCTOR_OUTPUT}"
  check_success "Brew doctor diagnostic"

fi

show_log "✅ Homebrew and package setup completed successfully"
