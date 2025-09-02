#!/usr/bin/env bash
#
# setup-bash-configuration.sh - Bash configuration setup module
#
# This script installs comprehensive bash configuration for both administrator and operator users.
# It sets up per-user configuration directories, symlinks, and profile redirectors for
# consistent bash environment across both accounts.
#
# Usage: ./setup-bash-configuration.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude (modularized from first-boot.sh)
# Version: 1.0
# Created: 2025-09-02

# Exit on any error
set -euo pipefail

# Parse command line arguments
FORCE=false
for arg in "$@"; do
  case ${arg} in
    --force)
      FORCE=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Load common configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${SETUP_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
else
  echo "Error: Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# Set derived variables
ADMIN_USERNAME=$(whoami)
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Set up logging
LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/${HOSTNAME_LOWER}-setup.log"
mkdir -p "${LOG_DIR}"

# Logging functions
log() {
  mkdir -p "${LOG_DIR}"
  local timestamp no_newline=false
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

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

show_log() {
  local no_newline=false

  if [[ "$1" == "-n" ]]; then
    no_newline=true
    echo -n "$2"
    log -n "$2"
  else
    echo "$1"
    log "$1"
  fi
}

section() {
  log "====== $1 ======"
}

# Error collection system (uses exported variables from parent script)
collect_error() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "❌ ${clean_message}"
  # Append to temporary file for cross-process collection (if available)
  if [[ -n "${SETUP_ERRORS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_ERRORS_FILE}"
  fi
}

# shellcheck disable=SC2329 # Function included for consistency across modules
collect_warning() {
  local message="$1"
  local line_number="${2:-${LINENO}}"
  local context="${CURRENT_SCRIPT_SECTION:-Unknown section}"
  local script_name
  script_name="$(basename "${BASH_SOURCE[1]:-${0}}")"

  local clean_message
  clean_message="$(echo "${message}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

  show_log "⚠️ ${clean_message}"
  # Append to temporary file for cross-process collection (if available)
  if [[ -n "${SETUP_WARNINGS_FILE:-}" ]]; then
    echo "[${script_name}:${line_number}] ${context}: ${clean_message}" >>"${SETUP_WARNINGS_FILE}"
  fi
}

set_section() {
  CURRENT_SCRIPT_SECTION="$1"
  section "$1"
}

check_success() {
  if [[ $? -eq 0 ]]; then
    show_log "✅ $1"
  else
    collect_error "$1 failed"
    if [[ "${FORCE}" == false ]]; then
      read -p "Continue anyway? (y/N) " -n 1 -r
      echo
      if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# BASH CONFIGURATION INSTALLATION
#

# Install Bash Configuration
set_section "Installing Bash Configuration for Administrator and Operator"

# Check if bash configuration is available in setup package
BASH_CONFIG_SOURCE="${SETUP_DIR}/bash"
if [[ -d "${BASH_CONFIG_SOURCE}" ]]; then
  log "Installing Bash configuration from setup package"

  # Function to install bash config for a user
  install_bash_config_for_user() {
    local username="$1"
    local user_home="$2"
    local user_config_dir="${user_home}/.config"
    local user_bash_config_dir="${user_config_dir}/bash"

    log "Installing Bash configuration for ${username}"

    # Create .config directory if it doesn't exist
    if [[ "${username}" == "${ADMIN_USERNAME}" ]]; then
      # Admin user - direct operations
      mkdir -p "${user_config_dir}"
    else
      # Operator user - use sudo -iu for proper environment
      sudo -p "[Bash config] Enter password to create config directory for ${username}: " -iu "${username}" mkdir -p "${user_config_dir}"
    fi

    # Copy bash configuration directory (ensure idempotency by copying contents, including dotfiles)
    if [[ "${username}" == "${ADMIN_USERNAME}" ]]; then
      mkdir -p "${user_bash_config_dir}"
      cp -r "${BASH_CONFIG_SOURCE}/"* "${user_bash_config_dir}/" 2>/dev/null || true
      cp -r "${BASH_CONFIG_SOURCE}/".[!.]* "${user_bash_config_dir}/" 2>/dev/null || true
      chown -R "${username}:staff" "${user_bash_config_dir}"
    else
      sudo -p "[Bash config] Enter password to create bash config directory for ${username}: " mkdir -p "${user_bash_config_dir}"
      sudo -p "[Bash config] Enter password to copy bash config for ${username}: " cp -r "${BASH_CONFIG_SOURCE}/"* "${user_bash_config_dir}/" 2>/dev/null || true
      sudo -p "[Bash config] Enter password to copy bash config for ${username}: " cp -r "${BASH_CONFIG_SOURCE}/".[!.]* "${user_bash_config_dir}/" 2>/dev/null || true
      sudo -p "[Bash config] Enter password to set ownership for ${username}: " chown -R "${username}:staff" "${user_bash_config_dir}"
    fi

    # Create symlink for .bash_profile
    local bash_profile_symlink="${user_home}/.bash_profile"
    local bash_profile_target="${user_bash_config_dir}/.bash_profile"

    if [[ "${username}" == "${ADMIN_USERNAME}" ]]; then
      # Remove existing .bash_profile if it's not already our symlink
      if [[ -f "${bash_profile_symlink}" && ! -L "${bash_profile_symlink}" ]]; then
        log "Backing up existing .bash_profile for ${username}"
        local timestamp
        timestamp="$(date +%Y%m%d-%H%M%S)"
        mv "${bash_profile_symlink}" "${bash_profile_symlink}.backup.${timestamp}"
      fi

      # Create the symlink
      ln -sf "${bash_profile_target}" "${bash_profile_symlink}"
    else
      # Operator user - use sudo -iu for proper environment
      if sudo -iu "${username}" test -f "${bash_profile_symlink}" && ! sudo -iu "${username}" test -L "${bash_profile_symlink}"; then
        log "Backing up existing .bash_profile for ${username}"
        local timestamp
        timestamp="$(date +%Y%m%d-%H%M%S)"
        sudo -p "[Bash config] Enter password to backup existing bash_profile for ${username}: " -iu "${username}" mv "${bash_profile_symlink}" "${bash_profile_symlink}.backup.${timestamp}"
      fi

      # Create the symlink
      sudo -p "[Bash config] Enter password to create bash_profile symlink for ${username}: " -iu "${username}" ln -sf "${bash_profile_target}" "${bash_profile_symlink}"
    fi

    # Create .profile redirector
    local profile_file="${user_home}/.profile"
    local profile_content="[ -r \$HOME/.bash_profile ] && . \$HOME/.bash_profile"

    if [[ "${username}" == "${ADMIN_USERNAME}" ]]; then
      # Check if .profile already has the redirector
      if [[ ! -f "${profile_file}" ]] || ! grep -q "\.bash_profile" "${profile_file}"; then
        log "Creating .profile redirector for ${username}"
        echo "${profile_content}" >>"${profile_file}"
      else
        log ".profile redirector already exists for ${username}"
      fi
    else
      # Operator user - use sudo -iu for proper environment
      if ! sudo -iu "${username}" test -f "${profile_file}" || ! sudo -iu "${username}" grep -q "\.bash_profile" "${profile_file}"; then
        log "Creating .profile redirector for ${username}"
        echo "${profile_content}" | sudo -p "[Bash config] Enter password to create profile redirector for ${username}: " -iu "${username}" tee -a "${profile_file}" >/dev/null
      else
        log ".profile redirector already exists for ${username}"
      fi
    fi

    log "✅ Bash configuration installed for ${username}"
  }

  # Install for Administrator
  install_bash_config_for_user "${ADMIN_USERNAME}" "/Users/${ADMIN_USERNAME}"

  # Install for Operator (if configured and account exists)
  if [[ -n "${OPERATOR_USERNAME:-}" ]] && dscl . -list /Users 2>/dev/null | grep -q "^${OPERATOR_USERNAME}$"; then
    install_bash_config_for_user "${OPERATOR_USERNAME}" "/Users/${OPERATOR_USERNAME}"
  else
    log "Operator account not configured or not found - skipping bash config installation for operator"
  fi

  check_success "Bash configuration installation"
else
  log "No bash configuration found in setup package - skipping bash config installation"
fi

show_log "✅ Bash configuration module completed successfully"

exit 0
