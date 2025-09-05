#!/usr/bin/env bash
#
# run-app-setup.sh - Application setup orchestrator for Mac Mini server
#
# This script runs all app-setup scripts in the optimal dependency order:
# 1. rclone-setup.sh - Cloud storage synchronization (independent)
# 2. transmission-setup.sh - Torrent client (downloads content)
# 3. filebot-setup.sh - Media file organization (processes downloads)
# 4. catch-setup.sh - RSS feed automation (monitors for new content)
# 5. plex-setup.sh - Media server (serves organized content)
#
# Unknown setup scripts are executed after the known ordered scripts.
#
# Usage: ./run-app-setup.sh [--force] [--continue-on-error] [--only SCRIPT]
#   --force: Pass --force flag to all setup scripts (skip prompts)
#   --continue-on-error: Continue running remaining scripts if one fails
#   --only SCRIPT: Run only the specified script (e.g., --only plex-setup.sh)
#
# Exit codes:
#   0: All scripts completed successfully
#   1: Configuration or environment error
#   2: One or more app setup scripts failed
#
# Author: Claude
# Version: 1.0
# Created: 2025-09-05

# Exit on error (but can be overridden with --continue-on-error)
set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate working directory
if [[ "${PWD}" != "${SCRIPT_DIR}" ]] || [[ "$(basename "${SCRIPT_DIR}")" != "app-setup" ]]; then
  echo "❌ Error: This script must be run from the app-setup directory"
  echo ""
  echo "Current directory: ${PWD}"
  echo "Script directory: ${SCRIPT_DIR}"
  echo ""
  echo "Please change to the app-setup directory and try again:"
  echo "  cd \"${SCRIPT_DIR}\" && ./run-app-setup.sh"
  echo ""
  exit 1
fi

# Load server configuration
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
else
  echo "❌ Error: Configuration file not found at ${CONFIG_FILE}"
  echo "Please ensure first-boot.sh completed successfully"
  exit 1
fi

# Derive configuration variables
HOSTNAME="${HOSTNAME_OVERRIDE:-${SERVER_NAME}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME}")"

# Logging configuration
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-app-setup.log"
mkdir -p "$(dirname "${LOG_FILE}")"

# Error and warning collection
declare -a COLLECTED_ERRORS=()
declare -a COLLECTED_WARNINGS=()
CURRENT_SECTION="App Setup Orchestrator"

# Parse command line arguments
FORCE=false
CONTINUE_ON_ERROR=false
ONLY_SCRIPT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --continue-on-error)
      CONTINUE_ON_ERROR=true
      shift
      ;;
    --only)
      ONLY_SCRIPT="$2"
      shift 2
      ;;
    -h | --help)
      echo "Usage: $0 [--force] [--continue-on-error] [--only SCRIPT]"
      echo ""
      echo "Options:"
      echo "  --force             Skip all confirmation prompts in setup scripts"
      echo "  --continue-on-error Continue running remaining scripts if one fails"
      echo "  --only SCRIPT       Run only the specified script (e.g., plex-setup.sh)"
      echo ""
      echo "App execution order:"
      echo "  1. rclone-setup.sh      (Cloud storage sync)"
      echo "  2. transmission-setup.sh (Torrent client)"
      echo "  3. filebot-setup.sh     (Media organization)"
      echo "  4. catch-setup.sh       (RSS automation)"
      echo "  5. plex-setup.sh        (Media server)"
      echo ""
      exit 0
      ;;
    *)
      echo "❌ Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Override error handling if continue-on-error is specified
if [[ "${CONTINUE_ON_ERROR}" == true ]]; then
  set +e
fi

# Logging functions (matching project conventions)
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${timestamp} - $*" | tee -a "${LOG_FILE}"
}

section() {
  echo ""
  echo "=== $* ==="
  log "SECTION: $*"
  CURRENT_SECTION="$*"
}

collect_error() {
  local error_msg="[${CURRENT_SECTION}] $*"
  COLLECTED_ERRORS+=("${error_msg}")
  echo "❌ ${error_msg}" | tee -a "${LOG_FILE}"
}

collect_warning() {
  local warning_msg="[${CURRENT_SECTION}] $*"
  COLLECTED_WARNINGS+=("${warning_msg}")
  echo "⚠️ ${warning_msg}" | tee -a "${LOG_FILE}"
}

check_success() {
  local exit_code=$1
  local operation="$2"

  if [[ ${exit_code} -eq 0 ]]; then
    log "✅ ${operation}"
    return 0
  else
    collect_error "${operation} failed with exit code ${exit_code}"
    if [[ "${CONTINUE_ON_ERROR}" != true ]]; then
      show_collected_issues
      exit 2
    fi
    return 1
  fi
}

show_collected_issues() {
  if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]] || [[ ${#COLLECTED_WARNINGS[@]} -gt 0 ]]; then
    echo ""
    echo "=== SUMMARY OF ISSUES ==="

    if [[ ${#COLLECTED_ERRORS[@]} -gt 0 ]]; then
      echo ""
      echo "ERRORS (${#COLLECTED_ERRORS[@]}):"
      for error in "${COLLECTED_ERRORS[@]}"; do
        echo "  ❌ ${error}"
      done
    fi

    if [[ ${#COLLECTED_WARNINGS[@]} -gt 0 ]]; then
      echo ""
      echo "WARNINGS (${#COLLECTED_WARNINGS[@]}):"
      for warning in "${COLLECTED_WARNINGS[@]}"; do
        echo "  ⚠️ ${warning}"
      done
    fi

    echo ""
  fi
}

# Define optimal execution order with descriptions
declare -A SCRIPT_ORDER=(
  ["rclone-setup.sh"]="1:Cloud storage synchronization"
  ["transmission-setup.sh"]="2:Torrent client"
  ["filebot-setup.sh"]="3:Media file organization"
  ["catch-setup.sh"]="4:RSS feed automation"
  ["plex-setup.sh"]="5:Media server"
)

# Function to get all setup scripts
get_setup_scripts() {
  local scripts=()

  # If --only specified, return just that script
  if [[ -n "${ONLY_SCRIPT}" ]]; then
    if [[ -f "${SCRIPT_DIR}/${ONLY_SCRIPT}" ]]; then
      scripts=("${ONLY_SCRIPT}")
    else
      collect_error "Specified script '${ONLY_SCRIPT}' not found"
      return 1
    fi
  else
    # Find all *-setup.sh scripts in current directory only (exclude this wrapper)
    for script_path in "${SCRIPT_DIR}"/*-setup.sh; do
      # Check if glob matched actual files
      [[ -f "${script_path}" ]] || continue

      local script_name
      script_name="$(basename "${script_path}")"

      # Exclude the wrapper script itself
      if [[ "${script_name}" != "run-app-setup.sh" ]]; then
        scripts+=("${script_name}")
      fi
    done
  fi

  printf '%s\n' "${scripts[@]}"
}

# Function to sort scripts by dependency order
sort_scripts_by_order() {
  local -a scripts=("$@")
  local -a ordered_scripts=()
  local -a unknown_scripts=()

  # First pass: collect scripts in defined order
  for order_num in {1..9}; do
    for script in "${scripts[@]}"; do
      local order_info="${SCRIPT_ORDER[${script}]:-}"
      if [[ -n "${order_info}" ]] && [[ "${order_info%%:*}" == "${order_num}" ]]; then
        ordered_scripts+=("${script}")
      fi
    done
  done

  # Second pass: collect unknown scripts
  for script in "${scripts[@]}"; do
    if [[ -z "${SCRIPT_ORDER[${script}]:-}" ]]; then
      unknown_scripts+=("${script}")
    fi
  done

  # Output ordered scripts first, then unknown scripts
  printf '%s\n' "${ordered_scripts[@]}" "${unknown_scripts[@]}"
}

# Function to run a setup script
run_setup_script() {
  local script_name="$1"
  local script_path="${SCRIPT_DIR}/${script_name}"
  local description="${SCRIPT_ORDER[${script_name}]:-}"

  if [[ -n "${description}" ]]; then
    description="${description#*:}" # Remove order prefix
    section "Running ${script_name} - ${description}"
  else
    section "Running ${script_name} - Unknown setup script"
  fi

  if [[ ! -f "${script_path}" ]]; then
    collect_error "Setup script not found: ${script_path}"
    return 1
  fi

  if [[ ! -x "${script_path}" ]]; then
    collect_error "Setup script not executable: ${script_path}"
    return 1
  fi

  # Build command with appropriate flags
  local cmd=("${script_path}")
  if [[ "${FORCE}" == true ]]; then
    cmd+=("--force")
  fi

  log "Executing: ${cmd[*]}"

  # Run the script and capture exit code
  local exit_code=0
  "${cmd[@]}" || exit_code=$?

  check_success "${exit_code}" "${script_name} execution"
  return "${exit_code}"
}

# Main execution
main() {
  section "App Setup Orchestrator Starting"
  log "Running from: ${PWD}"
  log "Configuration: ${CONFIG_FILE}"
  log "Log file: ${LOG_FILE}"
  log "Force mode: ${FORCE}"
  log "Continue on error: ${CONTINUE_ON_ERROR}"

  if [[ -n "${ONLY_SCRIPT}" ]]; then
    log "Running only: ${ONLY_SCRIPT}"
  fi

  # Get and sort setup scripts
  local -a scripts
  mapfile -t scripts < <(get_setup_scripts) || true

  if [[ ${#scripts[@]} -eq 0 ]]; then
    collect_warning "No setup scripts found to execute"
    show_collected_issues
    return 0
  fi

  # Sort scripts by dependency order
  local -a sorted_scripts
  mapfile -t sorted_scripts < <(sort_scripts_by_order "${scripts[@]}") || true

  log "Found ${#scripts[@]} setup script(s) to execute"

  # Show execution plan
  echo ""
  echo "=== EXECUTION PLAN ==="
  local script_num=1
  for script in "${sorted_scripts[@]}"; do
    local description="${SCRIPT_ORDER[${script}]:-}"
    if [[ -n "${description}" ]]; then
      description="${description#*:}"
      echo "${script_num}. ${script} - ${description}"
    else
      echo "${script_num}. ${script} - Unknown setup script"
    fi
    ((script_num += 1))
  done
  echo ""

  # Confirm execution unless --force specified
  if [[ "${FORCE}" != true ]]; then
    read -r -p "Proceed with app setup? (Y/n): " response
    case "${response}" in
      [nN][oO] | [nN])
        echo "App setup cancelled by user"
        exit 0
        ;;
      *)
        echo "Proceeding with app setup..."
        ;;
    esac
  fi

  # Execute scripts in order
  local failed_scripts=0
  local successful_scripts=0

  for script in "${sorted_scripts[@]}"; do
    if run_setup_script "${script}"; then
      ((successful_scripts += 1))
    else
      ((failed_scripts += 1))
      if [[ "${CONTINUE_ON_ERROR}" != true ]]; then
        break
      fi
    fi
  done

  # Final summary
  section "App Setup Complete"
  log "Successful: ${successful_scripts}"
  log "Failed: ${failed_scripts}"

  show_collected_issues

  if [[ ${failed_scripts} -gt 0 ]]; then
    if [[ "${CONTINUE_ON_ERROR}" == true ]]; then
      echo "⚠️ App setup completed with ${failed_scripts} failure(s)"
      echo "Check the log file for details: ${LOG_FILE}"
      return 2
    else
      echo "❌ App setup failed"
      return 2
    fi
  else
    echo "✅ All app setup scripts completed successfully"
    return 0
  fi
}

# Execute main function
main "$@"
