#!/usr/bin/env bash
#
# setup-package-installation.sh - Homebrew and package installation
#
# This script handles Homebrew installation and package management for the
# Mac Mini server. It includes:
# - Homebrew installation and configuration
# - Package installation from formulae and casks lists
# - Quarantine removal for installed applications
# - Performance optimization and cleanup
#
# Usage: ./setup-package-installation.sh [--force] [--skip-homebrew] [--skip-packages]
#   --force: Skip all confirmation prompts
#   --skip-homebrew: Skip Homebrew installation/update
#   --skip-packages: Skip package installation
#
# Author: Claude
# Version: 1.0
# Created: 2025-09-05

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
      echo "Usage: $0 [--force] [--skip-homebrew] [--skip-packages]"
      exit 1
      ;;
  esac
done

# Configuration loading with fallback to environment variable
if [[ -n "${SETUP_DIR:-}" ]]; then
  CONFIG_FILE="${SETUP_DIR}/config/config.conf"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SETUP_DIR="$(dirname "${SCRIPT_DIR}")"
  CONFIG_FILE="${SETUP_DIR}/config/config.conf"
fi

# Load configuration
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "❌ Configuration file not found: ${CONFIG_FILE}"
  exit 1
fi

# Set derived variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Set up logging
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# log function - only writes to log file
log() {
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

# New wrapper function - shows in main window AND logs
show_log() {
  local no_newline=false

  # Check for -n flag
  if [[ "$1" == "-n" ]]; then
    no_newline=true
    echo -n "$2"
    log -n "$2"
  else
    echo "$1"
    log "$1"
  fi
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Error collection system (minimal for module)
COLLECTED_ERRORS=()
CURRENT_SCRIPT_SECTION=""

# Function to set current script section for context
set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

# Function to collect an error (with immediate display)
collect_error() {
  local message="$1"
  local line_number="${2:-}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  # Normalize message to single line
  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  COLLECTED_ERRORS+=("[${script_name}:${line_number}] ${context}: ${clean_message}")
}

# Function to check if a command was successful
check_success() {
  if [[ $? -eq 0 ]]; then
    show_log "✅ $1"
  else
    collect_error "$1 failed"
    if [[ "${FORCE}" = false ]]; then
      read -p "Continue anyway? (y/N) " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        exit 1
      fi
    fi
  fi
}

# Set up required variables with fallbacks
ADMIN_USERNAME="${ADMIN_USERNAME:-$(whoami)}"
# HOMEBREW_PREFIX is set and exported by first-boot.sh based on architecture
if [[ -z "${HOMEBREW_PREFIX:-}" ]]; then
  echo "Error: HOMEBREW_PREFIX not set - this script must be run from first-boot.sh"
  exit 1
fi
FORMULAE_FILE="${FORMULAE_FILE:-${SETUP_DIR}/config/formulae.txt}"
CASKS_FILE="${CASKS_FILE:-${SETUP_DIR}/config/casks.txt}"

# Install Homebrew
set_section "Installing Homebrew"
if [[ "${SKIP_HOMEBREW}" = false ]]; then
  section "Installing Homebrew"

  # Check if Homebrew is already installed
  if command -v brew &>/dev/null; then
    BREW_VERSION=$("${HOMEBREW_PREFIX}/bin/brew" --version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "unknown")
    log "Homebrew is already installed (version ${BREW_VERSION})"

    # Update Homebrew if already installed
    log "Updating Homebrew"
    "${HOMEBREW_PREFIX}/bin/brew" update
    check_success "Homebrew update"
    log "Updating installed packages"
    "${HOMEBREW_PREFIX}/bin/brew" upgrade
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
    if "${HOMEBREW_PREFIX}/bin/brew" help >/dev/null 2>&1; then
      show_log "✅ Homebrew verification successful"
    else
      collect_error "Homebrew verification failed - brew help returned an error"
      exit 1
    fi
  fi
fi

# Add concurrent download configuration
section "Configuring Homebrew for Optimal Performance"
export HOMEBREW_DOWNLOAD_CONCURRENCY=auto
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo "2x")"
log "Enabled concurrent downloads (auto mode - using ${CORES} CPU cores for optimal parallelism)"

# Install packages
set_section "Installing Homebrew formulae and casks"
if [[ "${SKIP_PACKAGES}" = false ]]; then
  section "Installing Packages"

  # Function to install formulae if not already installed
  install_formula() {
    if ! "${HOMEBREW_PREFIX}/bin/brew" list "$1" &>/dev/null; then
      log "Installing formula: $1"
      if "${HOMEBREW_PREFIX}/bin/brew" install "$1"; then
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
    if ! "${HOMEBREW_PREFIX}/bin/brew" list --cask "$1" &>/dev/null; then
      log "Installing cask: $1"

      # Capture /Applications before installation
      local before_apps
      before_apps=$(find /Applications -maxdepth 1 -type d -name "*.app" 2>/dev/null | sort)

      if "${HOMEBREW_PREFIX}/bin/brew" install --cask "$1"; then
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
  "${HOMEBREW_PREFIX}/bin/brew" cleanup
  check_success "Homebrew cleanup"

  # Run brew doctor and save output
  log "Running brew doctor diagnostic"
  BREW_DOCTOR_OUTPUT="${LOG_DIR}/brew-doctor-$(date +%Y%m%d-%H%M%S).log"
  "${HOMEBREW_PREFIX}/bin/brew" doctor >"${BREW_DOCTOR_OUTPUT}" 2>&1 || true
  log "Brew doctor output saved to: ${BREW_DOCTOR_OUTPUT}"
  check_success "Brew doctor diagnostic"

fi

# Reload profile for current session
section "Reload Profile"
# shellcheck source=/dev/null
source ~/.zprofile
check_success "Reload profile"

show_log "✅ Package installation setup completed"
