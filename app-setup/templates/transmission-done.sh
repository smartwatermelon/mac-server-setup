#!/usr/bin/env bash

# Detect architecture and set Homebrew prefix BEFORE strict mode
ARCH="$(arch)"
case "${ARCH}" in
  i386 | x86_64)
    # Intel Macs (both old i386 and modern x86_64)
    export HOMEBREW_PREFIX="/usr/local"
    ;;
  arm64)
    # Apple Silicon Macs
    export HOMEBREW_PREFIX="/opt/homebrew"
    ;;
  *)
    printf 'Error: Unsupported architecture: %s\n' "${ARCH}" >&2
    exit 1
    ;;
esac

# Set PATH to include Homebrew and common locations
PATH="/usr/bin:/bin:/usr/sbin:/sbin:${HOMEBREW_PREFIX}/bin:/usr/local/bin"
export PATH

# Strict mode (without -e to allow error logging instead of immediate exit)
set -uo pipefail
IFS=$'\n\t'

# Signal handling
trap 'log "Script interrupted"; exit 1' INT TERM

# NFS-safe file discovery using shell globbing.
# On NFS mounts accessed from macOS LaunchAgent processes, find(1) fails with
# "Operation not permitted" because it uses open(O_DIRECTORY) which macOS blocks.
# Shell globbing uses opendir()/readdir() which is permitted.
find_media_files() {
  local dir="$1"
  local media_extensions='mkv|mp4|avi|m4v'

  # If TR_TORRENT_FILES is set (provided by trigger watcher via Transmission RPC),
  # use it directly instead of listing the directory. This works around a macOS
  # restriction where background LaunchAgent processes get EPERM from opendir()
  # on NFS-mounted directories, even though stat() on individual files works.
  if [[ -n "${TR_TORRENT_FILES:-}" ]]; then
    echo "${TR_TORRENT_FILES}" | grep -iE "\.(${media_extensions})$" || true
    return
  fi

  # Fallback: shell globbing for manual mode or when file list is unavailable.
  # Searches 2 levels deep (covers typical torrent layouts: dir/file and dir/sub/file).
  (
    shopt -s nullglob nocaseglob
    local -a files=()
    for ext in mkv mp4 avi m4v; do
      files+=("${dir}"/*."${ext}" "${dir}"/*/*."${ext}")
    done
    if [[ ${#files[@]} -gt 0 ]]; then
      printf '%s\n' "${files[@]}"
    fi
  )
}

# Test mode flags
TEST_MODE="${TEST_MODE:-false}"
TEST_RUNNER="${TEST_RUNNER:-false}"

# Resolve symlinks to get real script location
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "${SCRIPT_SOURCE}" ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
  SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
  [[ ${SCRIPT_SOURCE} != /* ]] && SCRIPT_SOURCE="${SCRIPT_DIR}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
readonly SCRIPT_DIR

# Derive HOME from script path (assumes script is in user's home directory tree)
if [[ "${SCRIPT_DIR}" =~ ^(/Users/[^/]+) ]]; then
  DERIVED_HOME="${BASH_REMATCH[1]}"
elif [[ "${SCRIPT_DIR}" =~ ^(/home/[^/]+) ]]; then
  DERIVED_HOME="${BASH_REMATCH[1]}"
else
  # Fallback: try USER variable, then whoami, then generic default
  if [[ -n "${USER:-}" ]]; then
    DERIVED_HOME="/Users/${USER}"
  else
    # Use whoami as final fallback (works even in minimal environments)
    DERIVED_HOME="/Users/$(whoami)"
  fi
fi

# Use HOME if set and valid, otherwise use derived value
EFFECTIVE_HOME="${HOME:-${DERIVED_HOME}}"
readonly EFFECTIVE_HOME

# Constants
readonly LOCAL_CONFIG="${SCRIPT_DIR}/config.yml"
readonly USER_CONFIG="${EFFECTIVE_HOME}/.config/transmission-done/config.yml"
readonly CURL_OPTS=(-s -f -m 10 -v) # silent, fail on error, 10 second timeout, verbose

# Dependency paths (use full paths to avoid PATH issues in Transmission environment)
readonly YQ="${HOMEBREW_PREFIX}/bin/yq"
readonly FILEBOT="${HOMEBREW_PREFIX}/bin/filebot"

# Config vars
PLEX_SERVER=""
PLEX_TOKEN=""
PLEX_MEDIA_PATH="${PLEX_MEDIA_PATH:-}"
LOG_FILE=""
MAX_LOG_SIZE=0

# Invocation mode tracking
INVOCATION_MODE=""

# Triage tracking — set to true by triage_failed_torrent(), read by main()
TRIAGE_PERFORMED=false

# Preview output storage
LAST_PREVIEW_OUTPUT=""

# Last successful FileBot output (for Plex scan type detection)
LAST_FILEBOT_OUTPUT=""

# Config validation functions
validate_config_file() {
  local config_file="$1"
  if ! "${YQ}" eval '.' "${config_file}" >/dev/null 2>&1; then
    printf 'Error: Invalid YAML in config file: %s\n' "${config_file}" >&2
    return 1
  fi
  return 0
}

get_home_directory() {
  local config_file="$1"
  local default_home

  default_home=$("${YQ}" eval '.paths.default_home' "${config_file}")
  if [[ -z "${default_home}" ]]; then
    printf 'Error: default_home not set in config\n' >&2
    return 1
  fi

  if [[ -n "${HOME:-}" ]] && [[ -d "${HOME}" ]]; then
    printf '%s' "${HOME}"
  else
    printf '%s' "${default_home}"
  fi
}

read_config() {
  if ! "${YQ}" --version &>/dev/null; then
    printf 'Error: yq required at %s\nTry: brew install yq\n' "${YQ}" >&2
    return 1
  fi

  local config_file
  if [[ -f "${LOCAL_CONFIG}" ]]; then
    config_file="${LOCAL_CONFIG}"
  elif [[ -f "${USER_CONFIG}" ]]; then
    config_file="${USER_CONFIG}"
  else
    printf 'Error: No config file found. Checked:\n%s\n%s\n' "${LOCAL_CONFIG}" "${USER_CONFIG}" >&2
    return 1
  fi

  validate_config_file "${config_file}" || return 1

  local effective_home
  effective_home=$(get_home_directory "${config_file}") || return 1

  PLEX_SERVER=$("${YQ}" eval '.plex.server' "${config_file}")
  PLEX_TOKEN=$("${YQ}" eval '.plex.token' "${config_file}")
  PLEX_MEDIA_PATH=$("${YQ}" eval '.plex.media_path' "${config_file}")

  local missing_values=()
  [[ -z "${PLEX_SERVER}" ]] && missing_values+=("plex.server")
  [[ -z "${PLEX_TOKEN}" ]] && missing_values+=("plex.token")
  [[ -z "${PLEX_MEDIA_PATH}" ]] && missing_values+=("plex.media_path")

  if ((${#missing_values[@]} > 0)); then
    printf 'Error: Missing required config values: %s\n' "${missing_values[*]}" >&2
    return 1
  fi

  local log_path
  log_path=$("${YQ}" eval '.logging.file' "${config_file}")
  LOG_FILE="${effective_home}/${log_path}"
  MAX_LOG_SIZE=$("${YQ}" eval '.logging.max_size' "${config_file}")

  if [[ "${TEST_MODE}" != "true" ]]; then
    printf 'Using config file: %s\n' "${config_file}" >&2
  fi
}

# Log function with timestamp
log() {
  if [[ ! -d "$(dirname "${LOG_FILE}")" ]]; then
    printf 'Warning: Log directory does not exist: %s\n' "$(dirname "${LOG_FILE}")" >&2
    mkdir -p "$(dirname "${LOG_FILE}")"
  fi
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  # In test mode, only write to log file (don't output to stdout)
  if [[ "${TEST_MODE}" == "true" ]]; then
    printf '[%s] %s\n' "${timestamp}" "$1" >>"${LOG_FILE}"
  else
    printf '[%s] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
  fi
}

# Plex API functions
plex_make_request() {
  local endpoint="$1"
  local max_retries="${2:-1}"
  local retry_delay="${3:-5}"
  local attempt=1

  while [[ ${attempt} -le ${max_retries} ]]; do
    if [[ "${TEST_MODE}" == "true" ]]; then
      log "TEST: Would make Plex request to ${endpoint}"
      return 0
    fi

    local response
    response=$(curl "${CURL_OPTS[@]}" -H "X-Plex-Token: ${PLEX_TOKEN}" \
      "${PLEX_SERVER}${endpoint}" 2>&1)
    local curl_exit=$?

    if [[ ${curl_exit} -eq 0 ]]; then
      echo "${response}"
      return 0
    else
      log "Warning: Plex request failed (attempt ${attempt}/${max_retries})"
      log "Endpoint: ${endpoint}"
      log "Exit code: ${curl_exit}"
      log "Response: ${response}"

      if [[ ${attempt} -lt ${max_retries} ]]; then
        log "Retrying in ${retry_delay} seconds..."
        sleep "${retry_delay}"
      fi
    fi
    ((attempt += 1))
  done

  return 1
}

verify_plex_connection() {
  local test_mode="$1"
  if [[ "${test_mode}" == "true" ]]; then
    log "TEST: Would verify Plex connection"
    return 0
  fi

  log "Verifying Plex connection on ${PLEX_SERVER}..."
  if ! plex_make_request "/identity"; then
    log "Error: Cannot connect to Plex server"
    log "Server: ${PLEX_SERVER}"
    log "Token: ${PLEX_TOKEN:0:3}...${PLEX_TOKEN: -3}"
    return 1
  fi
  log "Plex connection verified"
  return 0
}

# Check for required and optional dependencies
check_dependencies() {
  local missing_required=()
  local missing_optional=()
  local has_errors=false

  # Required dependencies
  local required_deps=("yq" "curl" "lsof" "find" "stat")

  for cmd in "${required_deps[@]}"; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing_required+=("${cmd}")
      has_errors=true
    fi
  done

  # Check for FileBot using globally defined path
  if [[ ! -x "${FILEBOT}" ]]; then
    missing_required+=("filebot (expected at ${FILEBOT})")
    has_errors=true
  fi

  # Optional dependencies (for enhanced features)
  local optional_deps=("terminal-notifier" "osascript")

  for cmd in "${optional_deps[@]}"; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing_optional+=("${cmd}")
    fi
  done

  # Report missing required dependencies
  if [[ ${has_errors} == true ]]; then
    log "Error: Missing required dependencies:"
    for cmd in "${missing_required[@]}"; do
      log "  - ${cmd}"
    done

    # Provide installation instructions
    log ""
    log "Installation instructions:"
    log "  yq: brew install yq"
    log "  filebot: https://www.filebot.net/"
    log "  lsof, curl, find, stat: Should be pre-installed on macOS"

    return 1
  fi

  # Report missing optional dependencies
  if [[ ${#missing_optional[@]} -gt 0 ]]; then
    log "Note: Missing optional dependencies (reduced functionality):"
    for cmd in "${missing_optional[@]}"; do
      log "  - ${cmd}"
    done
    log "  terminal-notifier: brew install terminal-notifier (for notifications)"
    log "  osascript: Should be available on macOS (for folder picker)"
  fi

  log "Dependency check passed"
  return 0
}

get_plex_library_sections() {
  if [[ "${TEST_MODE}" == "true" ]]; then
    log "TEST: Would get Plex library sections"
    return 0
  fi

  log "Querying Plex library sections..."
  local response
  if response=$(plex_make_request "/library/sections"); then
    log "Library sections found:"
    echo "${response}" | grep -o '<Directory.*</Directory>' | while read -r section; do
      local id type title
      id=$(echo "${section}" | grep -o 'key="[^"]*"' | cut -d'"' -f2)
      type=$(echo "${section}" | grep -o 'type="[^"]*"' | cut -d'"' -f2)
      title=$(echo "${section}" | grep -o 'title="[^"]*"' | cut -d'"' -f2)
      log "Section ${id}: ${title} (${type})"
    done
    return 0
  fi
  return 1
}

trigger_plex_scan() {
  local section_type="$1"
  local section_id

  case "${section_type}" in
    "show") section_id="2" ;;
    "movie") section_id="1" ;;
    *)
      log "Error: Unknown media type for Plex scan: ${section_type}"
      return 1
      ;;
  esac

  log "Triggering Plex scan for ${section_type} library"
  if ! plex_make_request "/library/sections/${section_id}/refresh" 3 5; then
    log "Error: Failed to trigger Plex scan for ${section_type} library"
    return 1
  fi

  log "Plex scan triggered successfully"
  return 0
}

# FileBot wrapper function
run_filebot() {
  if [[ "${TEST_MODE}" == "true" ]]; then
    echo "TEST: filebot called with args: $*" >&2

    if [[ "${FILEBOT_TEST_OVERRIDE:-false}" == "true" ]]; then
      return 0
    fi

    # Preview mode (--action test) always succeeds with test output
    if [[ "$*" == *"--action test"* ]]; then
      echo "[TEST] [RENAME] from [file.mkv] to [processed.mkv]"
      return 0
    fi

    # Auto-detect mode (no --db flag) for test directories
    if [[ "$*" != *"--db"* ]]; then
      if [[ "$*" == *"/test/The.Show.S01E01"* || "$*" == *"/test/The.Movie.2024"* ]]; then
        echo "Processed files to output directory"
        return 0
      fi
    fi

    # Database-specific processing for test directories
    if [[ "$*" == *"TheTVDB"* && "$*" == *"/test/The.Show.S01E01"* ]]; then
      return 0
    elif [[ "$*" == *"TheMovieDB"* && "$*" == *"/test/The.Movie.2024"* ]]; then
      return 0
    fi

    return 1
  else
    # Use globally defined FILEBOT path
    "${FILEBOT}" "$@"
  fi
}

# Log FileBot error with structured information and actionable suggestions
log_filebot_error() {
  local exit_code="$1"
  local output="$2"
  local source_dir="$3"
  local database="${4:-auto-detect}"

  log "=== FILEBOT ERROR REPORT ==="
  log "Exit Code: ${exit_code}"
  log "Database: ${database}"
  log "Source Directory: ${source_dir}"

  # List all files in source directory
  log "Files in source directory:"
  if [[ -d "${source_dir}" ]]; then
    local file_list
    # TR_TORRENT_FILES contains all files (not just media) — better for diagnostics.
    # Fallback lists media files only (NFS-safe globbing), which is less complete but
    # still useful for error reports when the full file list is unavailable.
    file_list="${TR_TORRENT_FILES:-$(find_media_files "${source_dir}" 2>/dev/null || echo "Unable to list files")}"
    if [[ -n "${file_list}" ]]; then
      echo "${file_list}" | while IFS= read -r file; do
        log "  - $(basename "${file}")"
      done
    else
      log "  (no files found or unable to list)"
    fi
  else
    log "  (directory does not exist)"
  fi

  # Analyze error patterns in output
  log "Error Analysis:"

  # Connection errors
  if echo "${output}" | grep -iq "connection\|network\|timeout\|unreachable"; then
    log "  ⚠ CONNECTION: Network/database connection issue detected"
    log "    Suggestions:"
    log "    - Check internet connectivity"
    log "    - Verify database service is online (TheTVDB, TheMovieDB, etc.)"
    log "    - Try again in a few minutes"
  fi

  # Permission errors
  if echo "${output}" | grep -iq "permission\|denied\|cannot write\|read-only"; then
    log "  ⚠ PERMISSION: File/directory permission issue detected"
    log "    Suggestions:"
    log "    - Check write permissions on: ${PLEX_MEDIA_PATH}"
    log "    - Check read permissions on: ${source_dir}"
    log "    - Verify user has access to both directories"
  fi

  # License errors
  if echo "${output}" | grep -iq "license\|unregistered\|trial\|activation"; then
    log "  ⚠ LICENSE: FileBot license issue detected"
    log "    Suggestions:"
    log "    - Verify FileBot is properly licensed"
    log "    - Check license file location: ~/.filebot/license.txt"
    log "    - Run: filebot --license to check status"
  fi

  # Identification errors
  if echo "${output}" | grep -iq "unable to identify\|no match\|failed to fetch\|no results"; then
    log "  ⚠ IDENTIFICATION: Media identification failed"
    log "    Suggestions:"
    log "    - Check filename follows naming conventions"
    log "    - For TV: Include S##E## or ##x## pattern"
    log "    - For Movies: Include year (YYYY)"
    log "    - Try different database with --db flag"
    log "    - Consider manual lookup on TVDB/TMDB"
  fi

  # Disk space
  if echo "${output}" | grep -iq "no space\|disk full\|quota exceeded"; then
    log "  ⚠ DISK SPACE: Insufficient disk space"
    log "    Suggestions:"
    log "    - Check available space: df -h ${PLEX_MEDIA_PATH}"
    log "    - Free up space in destination"
  fi

  # Unknown error
  if ! echo "${output}" | grep -iq "connection\|network\|timeout\|permission\|license\|identify\|space"; then
    log "  ⚠ UNKNOWN: Error type not recognized"
    log "    Suggestions:"
    log "    - Review full FileBot output in log file"
    log "    - Check FileBot documentation"
    log "    - Verify FileBot installation: filebot --version"
  fi

  # Log excerpt of output (first/last few lines)
  log "FileBot Output (excerpt):"
  local line_count
  line_count=$(echo "${output}" | wc -l)
  if [[ ${line_count} -gt 20 ]]; then
    log "  (First 10 lines)"
    echo "${output}" | head -10 | while IFS= read -r line; do
      log "  ${line}"
    done
    log "  ..."
    log "  (Last 10 lines)"
    echo "${output}" | tail -10 | while IFS= read -r line; do
      log "  ${line}"
    done
  else
    echo "${output}" | while IFS= read -r line; do
      log "  ${line}"
    done
  fi

  log "=== END ERROR REPORT ==="
  return 0
}

# Classify a FileBot failure into a triage category.
# Reads the combined FileBot output from all fallback strategies.
# Returns one of: "already-in-plex", "no-match", "failed"
classify_failure() {
  local filebot_output="$1"

  # Already in Plex: FileBot found a match but the destination file exists
  if echo "${filebot_output}" | grep -qiE "already exists|Skipped.*already exists"; then
    echo "already-in-plex"
    return 0
  fi

  # No match: FileBot couldn't identify the media at all
  if echo "${filebot_output}" | grep -qiE "unable to identify|no match|no results|failed to fetch"; then
    echo "no-match"
    return 0
  fi

  # No match: FileBot found candidates but processed 0 files (ambiguous match)
  if echo "${filebot_output}" | grep -q "Processed 0 files"; then
    echo "no-match"
    return 0
  fi

  # Everything else: network errors, license issues, permissions, etc.
  echo "failed"
  return 0
}

check_disk_space() {
  local required_space=1000000 # 1GB in KB

  if ! df -P "${PLEX_MEDIA_PATH}" | awk -v space="${required_space}" 'NR==2 {exit($4<space)}'; then
    log "Error: Insufficient space on target filesystem (need ${required_space}KB)"
    return 1
  fi
  return 0
}

# Check if a single file is ready (quick check without sleep)
check_file_ready_quick() {
  local file="$1"

  log "  → Quick check starting for: $(basename "${file}")"

  # Check 1: lsof - is file open by Transmission? (skip in test mode)
  if [[ "${TEST_MODE}" != "true" ]]; then
    log "  → Running lsof check..."
    local lsof_output=""
    lsof_output=$(lsof -a -c transmission -w "${file}" 2>/dev/null || echo "")

    log "  → lsof check complete (output: ${#lsof_output} bytes)"

    # Only fail if lsof found the file is open
    if [[ -n "${lsof_output}" ]] && echo "${lsof_output}" | grep -q "${file}"; then
      log "File still open by Transmission: ${file}"
      return 1
    fi
  fi

  log "  → Checking for .part marker..."
  # Check 2: .part marker
  if [[ -f "${file}.part" ]]; then
    log "Incomplete marker found: ${file}.part"
    return 1
  fi

  log "  → Checking for .incomplete marker..."
  # Check 3: .incomplete marker
  if [[ -f "${file}.incomplete" ]]; then
    log "Incomplete marker found: ${file}.incomplete"
    return 1
  fi

  log "  → File passed all quick checks"
  return 0
}

# Check if all media files in directory are ready to process
check_files_ready() {
  local source_dir="$1"
  local stability_seconds="${2:-10}"

  log "Validating files are ready for processing (${stability_seconds}s stability check)"

  # NFS + VirtioFS cache invalidation: when Transmission completes a download inside
  # a podman container, the trigger file (on local disk) arrives before VirtioFS
  # propagates the directory metadata to the host NFS client. Force a readdir() to
  # refresh the NFS attribute cache, and retry if the directory appears empty.
  local media_files=""
  local nfs_retry
  for nfs_retry in 1 2 3; do
    # Force NFS directory cache revalidation by reading the directory listing
    ls "${source_dir}" >/dev/null 2>&1 || true

    # Use globbing instead of find(1) for NFS compatibility — see find_media_files()
    media_files=$(find_media_files "${source_dir}")

    if [[ -n "${media_files}" ]]; then
      break
    fi

    if [[ "${nfs_retry}" -lt 3 ]]; then
      log "No media files visible yet (NFS cache retry ${nfs_retry}/3, waiting 5s)"
      sleep 5
    fi
  done

  if [[ -z "${media_files}" ]]; then
    log "Warning: No media files found in ${source_dir} (after NFS cache retries)"
    return 1
  fi

  local file_count_preview
  file_count_preview=$(echo "${media_files}" | grep -c . || echo "0")
  log "Found ${file_count_preview} media files to validate"

  # Phase 1: Quick checks and initial sizes
  # Note: Storage uses pipe delimiter which is rare but technically allowed in filenames
  # If a filename contains '|', the extraction in Phase 3 will fail validation
  local file_count=0
  declare -A sizes_before

  # IMPORTANT: This loop must have identical iteration/filtering logic to Phase 3
  # Both loops read from ${media_files}, use same IFS/read, and increment at same point
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    ((file_count += 1))

    log "Checking file ${file_count}/${file_count_preview}: $(basename "${file}")"

    # Quick checks (lsof + markers)
    if ! check_file_ready_quick "${file}"; then
      log "File not ready: ${file}"
      return 1
    fi

    # In test mode, skip size checking (just validate markers)
    if [[ "${TEST_MODE}" == "true" ]]; then
      log "File ready (test mode): ${file}"
    else
      # Record initial size
      local file_size
      file_size=$(stat -f%z "${file}" 2>/dev/null || echo "0")

      # Store size using array index (file paths may contain brackets)
      sizes_before[${file_count}]="${file}|${file_size}"
    fi
  done <<<"${media_files}"

  log "Completed phase 1: checked ${file_count} files"

  # In test mode, we're done after marker checks
  if [[ "${TEST_MODE}" == "true" ]]; then
    log "All ${file_count} files validated and ready (test mode)"
    return 0
  fi

  # Phase 2: Sleep once for entire batch
  log "Sleeping ${stability_seconds}s to verify file stability (${file_count} files)"
  sleep "${stability_seconds}"

  # Phase 3: Check final sizes
  # IMPORTANT: This loop must have identical iteration/filtering logic to Phase 1
  # Any mismatch will be caught by the filepath validation below
  local phase3_count=0
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    ((phase3_count += 1))

    # Retrieve stored data (format: "filepath|size")
    local stored_data="${sizes_before[${phase3_count}]}"

    # Validate we have stored data for this index
    if [[ -z "${stored_data}" ]]; then
      log "ERROR: No stored data for index ${phase3_count} (file: ${file})"
      return 1
    fi

    # Extract and validate stored filepath matches current file
    local stored_path="${stored_data%|*}"
    if [[ "${stored_path}" != "${file}" ]]; then
      log "ERROR: File order mismatch at index ${phase3_count}"
      log "  Expected: ${file}"
      log "  Got:      ${stored_path}"
      return 1
    fi

    # Extract stored size
    local size_before="${stored_data#*|}"

    local size_after
    size_after=$(stat -f%z "${file}" 2>/dev/null || echo "0")

    if [[ "${size_before}" != "${size_after}" ]]; then
      log "File size changed: ${file} (${size_before} → ${size_after} bytes)"
      return 1
    fi

    log "File ready: ${file} (${size_after} bytes)"
  done <<<"${media_files}"

  log "All ${file_count} files validated and ready"
  return 0
}

# Discover and filter media files (for manual mode)
discover_and_filter_media_files() {
  local search_dir="$1"
  local include_incomplete="${2:-false}"

  log "Discovering media files in ${search_dir}"

  # Find all media files using NFS-safe globbing
  local all_files
  all_files=$(find_media_files "${search_dir}")

  if [[ -z "${all_files}" ]]; then
    log "No media files found"
    return 1
  fi

  local ready_count=0
  local incomplete_count=0
  local ready_files=""

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue

    if check_file_ready_quick "${file}"; then
      ((ready_count += 1))
      ready_files="${ready_files}${file}"$'\n'
    else
      ((incomplete_count += 1))
      if [[ "${include_incomplete}" == "true" ]]; then
        log "Including incomplete: ${file}"
        ready_files="${ready_files}${file}"$'\n'
      else
        log "Filtered incomplete: ${file}"
      fi
    fi
  done <<<"${all_files}"

  log "Discovery complete: ${ready_count} ready, ${incomplete_count} incomplete"

  if [[ ${ready_count} -eq 0 ]]; then
    log "Error: No ready files found"
    return 1
  fi

  # Output ready files
  echo -n "${ready_files}"
  return 0
}

process_tv_show() {
  local source_dir="$1"

  run_filebot -rename "${source_dir}" \
    --db TheTVDB \
    --format "{plex}" \
    --output "${PLEX_MEDIA_PATH}" \
    -r \
    --conflict auto \
    -non-strict \
    --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
    --action move \
    >>"${LOG_FILE}" 2>&1
}

process_movie() {
  local source_dir="$1"

  run_filebot -rename "${source_dir}" \
    --db TheMovieDB \
    --format "{plex}" \
    --output "${PLEX_MEDIA_PATH}" \
    -r \
    --conflict auto \
    --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
    --action move \
    >>"${LOG_FILE}" 2>&1
}

# Preview FileBot changes with dry-run
preview_filebot_changes() {
  local source_dir="$1"
  local db="${2:-}"

  log "Generating preview of changes"

  # Build FileBot arguments
  local filebot_args=(
    -rename "${source_dir}"
    --format "{plex}"
    --output "${PLEX_MEDIA_PATH}"
    -r
    --conflict auto
    -non-strict
    --action test # DRY-RUN MODE
  )

  # Add database if specified
  if [[ -n "${db}" ]]; then
    filebot_args+=(--db "${db}")
  fi

  # Run FileBot in test mode
  local preview_output preview_exit
  preview_output=$(run_filebot "${filebot_args[@]}" 2>&1)
  preview_exit=$?

  # Count files to process
  local file_count
  file_count=$(echo "${preview_output}" | grep -c "\[TEST\]" 2>/dev/null || printf "0")
  file_count="${file_count//[^0-9]/}" # Remove non-numeric characters including newlines

  # FileBot returns exit 1 when uncertain about database (TV vs Movie)
  # but may still successfully show preview. Only fail if no files found.
  if [[ ${preview_exit} -ne 0 ]]; then
    log "Preview exited with code ${preview_exit}"

    if [[ ${file_count} -eq 0 ]]; then
      log "Preview failed - no files found"
      log "${preview_output}"
      return 1
    fi

    log "Preview succeeded despite exit code (${file_count} files found)"
  fi

  if [[ ${file_count} -eq 0 ]]; then
    log "Warning: Preview shows no files to rename"
    return 1
  fi

  log "Preview: ${file_count} files to process"
  echo "${preview_output}" | grep "\[TEST\]" | tee -a "${LOG_FILE}"

  # Store output for confirmation step
  LAST_PREVIEW_OUTPUT="${preview_output}"
  log "Preview stored (${#LAST_PREVIEW_OUTPUT} bytes)"
  return 0
}

# Confirm changes with user in manual mode
confirm_changes() {
  local summary="$1"

  # Automated mode: skip confirmation
  if [[ "${INVOCATION_MODE}" == "automated" ]]; then
    log "Automated mode: proceeding without confirmation"
    return 0
  fi

  # Manual mode: require confirmation
  log "Manual mode: requesting user confirmation"

  # Send notification if available
  if command -v terminal-notifier &>/dev/null; then
    terminal-notifier \
      -title "FileBot Preview" \
      -subtitle "${TR_TORRENT_NAME}" \
      -message "${summary}" \
      -sound "default" 2>/dev/null || true
  fi

  # Prompt for confirmation
  printf '\n%s\n' "${summary}"
  printf 'Proceed with these changes? [y/N]: '
  read -r response

  case "${response}" in
    [yY][eE][sS] | [yY])
      log "User confirmed: proceeding"
      return 0
      ;;
    *)
      log "User cancelled"
      return 1
      ;;
  esac
}

# Detect media type using filename heuristics
detect_media_type_heuristic() {
  local source_dir="$1"
  local tv_pattern_count=0
  local movie_pattern_count=0

  log "Analyzing media type using filename patterns"

  # Find all media files using NFS-safe globbing
  local media_files
  media_files=$(find_media_files "${source_dir}")

  if [[ -z "${media_files}" ]]; then
    log "No media files found for type detection"
    echo "unknown"
    return 1
  fi

  # Extract just the filenames (not full paths) for pattern matching
  # This prevents directory names from affecting detection
  # Use while loop to properly handle filenames with spaces
  local filenames=""
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    filenames="${filenames}$(basename "${file}")"$'\n'
  done <<<"${media_files}"

  log "Analyzing filenames: ${filenames}"

  # Count TV show patterns: S01E01, s1e1, 1x01, season, episode (case insensitive)
  tv_pattern_count=$(echo "${filenames}" | grep -icE 's[0-9]+e[0-9]+|[0-9]+x[0-9]+|season|episode') || tv_pattern_count=0

  # Count movie patterns: year 1900-2099, but NOT followed by 'p' or 'i' (to exclude 2160p, 1080i)
  # First grep finds years, second filters out resolution markers, then count
  movie_pattern_count=$(echo "${filenames}" | grep -iE '\b(19|20)[0-9]{2}\b' | grep -vicE '(19|20)[0-9]{2}[pi]') || movie_pattern_count=0

  log "Pattern counts - TV: ${tv_pattern_count:-0}, Movie: ${movie_pattern_count:-0}"

  # Determine type based on pattern prevalence (with safe defaults)
  if [[ ${tv_pattern_count:-0} -gt 0 ]] && [[ ${tv_pattern_count:-0} -ge ${movie_pattern_count:-0} ]]; then
    echo "tv"
    return 0
  elif [[ ${movie_pattern_count:-0} -gt 0 ]]; then
    echo "movie"
    return 0
  else
    log "Unable to determine type from patterns"
    echo "unknown"
    return 1
  fi
}

# Process media with FileBot auto-detection (no --db flag)
process_media_with_autodetect() {
  local source_dir="$1"

  log "Attempting FileBot auto-detection (no database specified)"

  local output exit_code
  output=$(run_filebot -rename "${source_dir}" \
    --format "{plex}" \
    --output "${PLEX_MEDIA_PATH}" \
    -r \
    --conflict auto \
    -non-strict \
    --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
    --action move \
    2>&1)
  exit_code=$?

  # Log the output and store for caller inspection (error diagnostics, Plex scan type)
  echo "${output}" >>"${LOG_FILE}"
  LAST_FILEBOT_OUTPUT="${output}"

  # In test mode with override, just check exit code
  if [[ "${FILEBOT_TEST_OVERRIDE:-false}" == "true" ]]; then
    return "${exit_code}"
  fi

  # Count files that were successfully moved (exclude "failed" lines —
  # FileBot emits "[MOVE] from X to Y failed due to ..." for I/O errors)
  local file_count
  file_count=$(echo "${output}" | grep "\[MOVE\]" | grep -vc "failed" 2>/dev/null || printf "0")
  file_count="${file_count//[^0-9]/}" # Remove non-numeric characters including newlines

  # FileBot returns exit 1 when uncertain about database (TV vs Movie)
  # but may still successfully move files. Only fail if no files were moved.
  if [[ ${exit_code} -ne 0 ]]; then
    log "Auto-detection exited with code ${exit_code}"

    if [[ ${file_count} -eq 0 ]]; then
      log "Auto-detection failed - no files moved"
      return 1
    fi

    log "Auto-detection succeeded despite exit code (${file_count} files moved)"
  fi

  if [[ ${file_count} -eq 0 ]]; then
    log "Warning: No files were moved"
    return 1
  fi
  log "Auto-detection: ${file_count} files moved successfully"
  return 0
}

# Process media with a specific database
process_with_database() {
  local source_dir="$1"
  local database="$2"

  log "Attempting FileBot processing with database: ${database}"

  local output exit_code
  output=$(run_filebot -rename "${source_dir}" \
    --db "${database}" \
    --format "{plex}" \
    --output "${PLEX_MEDIA_PATH}" \
    -r \
    --conflict auto \
    -non-strict \
    --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
    --action move \
    2>&1)
  exit_code=$?

  # Log the output and store for caller inspection
  echo "${output}" >>"${LOG_FILE}"
  LAST_FILEBOT_OUTPUT="${output}"

  # In test mode with override, just check exit code
  if [[ "${FILEBOT_TEST_OVERRIDE:-false}" == "true" ]]; then
    return "${exit_code}"
  fi

  # Count files that were successfully moved (exclude "failed" lines —
  # FileBot emits "[MOVE] from X to Y failed due to ..." for I/O errors)
  local file_count
  file_count=$(echo "${output}" | grep "\[MOVE\]" | grep -vc "failed" 2>/dev/null || printf "0")
  file_count="${file_count//[^0-9]/}" # Remove non-numeric characters including newlines

  # FileBot may return non-zero exit code even when files are moved successfully
  if [[ ${exit_code} -ne 0 ]]; then
    log "Database processing exited with code ${exit_code}"

    if [[ ${file_count} -eq 0 ]]; then
      log "Database processing failed - no files moved"
      return 1
    fi

    log "Database processing succeeded despite exit code (${file_count} files moved)"
  fi

  if [[ ${file_count} -eq 0 ]]; then
    log "Warning: No files were moved with database ${database}"
    return 1
  fi

  log "Database processing (${database}): ${file_count} files moved successfully"
  return 0
}

# Process with xattr cached metadata as last resort
process_with_xattr() {
  local source_dir="$1"

  log "Attempting FileBot processing with xattr cache (last resort)"

  local output exit_code
  # FileBot can use extended attributes cached from previous runs
  output=$(run_filebot -rename "${source_dir}" \
    --format "{plex}" \
    --output "${PLEX_MEDIA_PATH}" \
    -r \
    --conflict auto \
    --apply artwork url metadata import subtitles finder date chmod prune clean thumbnail \
    --action move \
    2>&1)
  exit_code=$?

  # Log the output and store for caller inspection
  echo "${output}" >>"${LOG_FILE}"
  LAST_FILEBOT_OUTPUT="${output}"

  # In test mode with override, just check exit code
  if [[ "${FILEBOT_TEST_OVERRIDE:-false}" == "true" ]]; then
    return "${exit_code}"
  fi

  # Count files that were successfully moved (exclude "failed" lines —
  # FileBot emits "[MOVE] from X to Y failed due to ..." for I/O errors)
  local file_count
  file_count=$(echo "${output}" | grep "\[MOVE\]" | grep -vc "failed" 2>/dev/null || printf "0")
  file_count="${file_count//[^0-9]/}" # Remove non-numeric characters including newlines

  # FileBot may return non-zero exit code even when files are moved successfully
  if [[ ${exit_code} -ne 0 ]]; then
    log "xattr processing exited with code ${exit_code}"

    if [[ ${file_count} -eq 0 ]]; then
      log "xattr processing failed - no files moved"
      return 1
    fi

    log "xattr processing succeeded despite exit code (${file_count} files moved)"
  fi

  if [[ ${file_count} -eq 0 ]]; then
    log "Warning: No files were moved with xattr cache"
    return 1
  fi

  log "xattr processing: ${file_count} files moved successfully"
  return 0
}

# Try TV show database chain
try_tv_databases() {
  local source_dir="$1"

  log "Trying TV database fallback chain"

  # Chain: TheTVDB → TheMovieDB::TV → AniDB
  local databases=("TheTVDB" "TheMovieDB::TV" "AniDB")

  for db in "${databases[@]}"; do
    log "Trying TV database: ${db}"
    if process_with_database "${source_dir}" "${db}"; then
      log "Success with TV database: ${db}"
      return 0
    fi
    log "Failed with TV database: ${db}"
  done

  return 1
}

# Try movie database chain
try_movie_databases() {
  local source_dir="$1"

  log "Trying movie database fallback chain"

  # Chain: TheMovieDB → OMDb
  local databases=("TheMovieDB" "OMDb")

  for db in "${databases[@]}"; do
    log "Trying movie database: ${db}"
    if process_with_database "${source_dir}" "${db}"; then
      log "Success with movie database: ${db}"
      return 0
    fi
    log "Failed with movie database: ${db}"
  done

  return 1
}

# Process media with comprehensive fallback strategy
process_media_with_fallback() {
  local source_dir="$1"
  local detected_type=""

  # Validate source path exists (may be a directory or single file)
  if [[ ! -e "${source_dir}" ]]; then
    log "Error: Source path does not exist: ${source_dir}"
    return 1
  fi

  log "Starting comprehensive fallback processing"

  # Strategy 1: Auto-detection (let FileBot decide)
  log "Strategy 1: FileBot auto-detection"
  if process_media_with_autodetect "${source_dir}"; then
    log "Success: FileBot auto-detection"
    return 0
  fi
  log "Failed: FileBot auto-detection"

  # Strategy 2: Heuristic detection + database chains
  log "Strategy 2: Heuristic detection with database fallback"
  detected_type=$(detect_media_type_heuristic "${source_dir}")

  if [[ "${detected_type}" == "tv" ]]; then
    log "Detected as TV show, trying TV database chain"
    if try_tv_databases "${source_dir}"; then
      log "Success: TV database chain"
      return 0
    fi
    log "Failed: TV database chain, trying movie databases as fallback"
    if try_movie_databases "${source_dir}"; then
      log "Success: Movie database fallback"
      return 0
    fi
  elif [[ "${detected_type}" == "movie" ]]; then
    log "Detected as movie, trying movie database chain"
    if try_movie_databases "${source_dir}"; then
      log "Success: Movie database chain"
      return 0
    fi
    log "Failed: Movie database chain, trying TV databases as fallback"
    if try_tv_databases "${source_dir}"; then
      log "Success: TV database fallback"
      return 0
    fi
  else
    log "Unknown type, trying both TV and movie databases"
    if try_tv_databases "${source_dir}"; then
      log "Success: TV database chain (unknown type)"
      return 0
    fi
    if try_movie_databases "${source_dir}"; then
      log "Success: Movie database chain (unknown type)"
      return 0
    fi
  fi

  # Strategy 3: xattr cache (last resort)
  log "Strategy 3: xattr cache (last resort)"
  if process_with_xattr "${source_dir}"; then
    log "Success: xattr cache"
    return 0
  fi
  log "Failed: xattr cache"

  log "Error: All fallback strategies exhausted"
  return 1
}

process_media() {
  local source_dir="$1"

  log "Processing media in ${source_dir}"

  # Step 1: Check disk space
  if ! check_disk_space; then
    log "Error: Disk space check failed"
    return 1
  fi

  # Step 2: Verify files are ready (not being downloaded)
  if ! check_files_ready "${source_dir}" 10; then
    log "Error: Files not ready for processing (still downloading or locked)"
    return 1
  fi

  # Step 3: Preview changes with dry-run
  if ! preview_filebot_changes "${source_dir}"; then
    log "Error: Preview failed - cannot determine what changes would be made"

    # In automated mode, triage the failure instead of leaving it in pending-move
    if [[ "${INVOCATION_MODE}" == "automated" ]]; then
      local category
      category=$(classify_failure "${LAST_PREVIEW_OUTPUT:-${LAST_FILEBOT_OUTPUT:-}}")
      local triage_base="${TR_TORRENT_DIR%/*}/triage"
      if triage_failed_torrent "${source_dir}" "${category}" "${triage_base}"; then
        return 0
      fi
    fi
    return 1
  fi

  # Step 4: Confirm changes with user (manual mode only)
  local file_count
  file_count=$(echo "${LAST_PREVIEW_OUTPUT}" | grep -c "\[TEST\]" || echo "0")
  if ! confirm_changes "${file_count} files ready to process"; then
    log "User cancelled processing"
    return 1
  fi

  # Step 5: Process with comprehensive fallback strategy
  LAST_FILEBOT_OUTPUT=""
  if ! process_media_with_fallback "${source_dir}"; then
    log "Error: All FileBot strategies failed"
    log_filebot_error 1 "${LAST_FILEBOT_OUTPUT}" "${source_dir}" "fallback-chain"

    # In automated mode, triage the failure instead of leaving it in pending-move
    if [[ "${INVOCATION_MODE}" == "automated" ]]; then
      local category
      category=$(classify_failure "${LAST_FILEBOT_OUTPUT}")
      local triage_base="${TR_TORRENT_DIR%/*}/triage"
      if triage_failed_torrent "${source_dir}" "${category}" "${triage_base}"; then
        # Return 0: the torrent is "handled" (triaged), trigger watcher should
        # clean up the trigger and remove from Transmission
        return 0
      fi
    fi
    return 1
  fi

  log "Successfully processed media"

  # Step 6: Cleanup and trigger Plex scan
  cleanup_empty_dirs "${source_dir}"

  # Determine media type from FileBot output for Plex scan
  # LAST_FILEBOT_OUTPUT is set by the successful processing function
  local detected_type="movie" # default
  if echo "${LAST_FILEBOT_OUTPUT}" | grep -iq "TV Shows"; then
    detected_type="show"
  fi

  trigger_plex_scan "${detected_type}"
  log "Processing completed successfully"
  return 0
}

cleanup_torrent() {
  local torrent_dir="$1"

  log "Cleaning up extraneous files in ${torrent_dir}"

  # When TR_TORRENT_FILES is available, derive junk file paths from the known
  # file list (replacing media extensions with junk extensions). This avoids
  # NFS opendir() which fails from LaunchAgent processes.
  if [[ -n "${TR_TORRENT_FILES:-}" ]]; then
    # TR_TORRENT_FILES contains ALL files (not just media), so we can clean
    # junk files that match known patterns by direct path (stat works on NFS).
    while IFS= read -r file_path; do
      [[ -z "${file_path}" ]] && continue
      # Safety: only delete files under the torrent directory
      [[ "${file_path}" == "${torrent_dir}/"* ]] || continue
      case "${file_path,,}" in
        *.nfo | *.exe | *.txt)
          rm -f "${file_path}" 2>/dev/null || true
          ;;
        *) ;;
      esac
    done <<<"${TR_TORRENT_FILES}"
    return 0
  fi

  # Fallback: globbing for manual mode
  (
    shopt -s nullglob nocaseglob
    for ext in nfo exe txt; do
      for f in "${torrent_dir}"/*."${ext}" "${torrent_dir}"/*/*."${ext}"; do
        rm -f "${f}"
      done
    done
  )
}

cleanup_empty_dirs() {
  local dir="$1"
  log "Cleaning up empty directories in ${dir}"
  # Repeat rmdir passes until no more empty dirs are removed (fully recursive,
  # NFS-safe — avoids find which gets EPERM from LaunchAgent processes).
  local removed=1
  while [[ "${removed}" -gt 0 ]]; do
    removed=0
    # Process deepest first: glob at increasing depth
    local d
    for d in "${dir}"/*/*/ "${dir}"/*/; do
      [[ -d "${d}" ]] || continue
      if rmdir "${d}" 2>/dev/null; then
        ((removed += 1))
      fi
    done
  done
}

# Move a failed torrent to a triage directory based on failure category.
# Args: $1=torrent_path, $2=category (from classify_failure), $3=triage_base_dir
# The triage directory structure is:
#   triage/already-in-plex/  — FileBot matched but destination exists
#   triage/no-match/         — FileBot couldn't identify the media
#   triage/failed/           — other errors (network, license, permissions)
triage_failed_torrent() {
  local torrent_path="$1"
  local category="$2"
  local triage_base="$3"
  local torrent_name
  torrent_name=$(basename "${torrent_path}")

  local dest_dir="${triage_base}/${category}"
  mkdir -p "${dest_dir}" 2>/dev/null || true

  # Handle name collision: append timestamp if destination already exists
  local dest="${dest_dir}/${torrent_name}"
  if [[ -e "${dest}" ]]; then
    dest="${dest_dir}/${torrent_name}.$(date +%Y%m%d-%H%M%S)"
  fi

  if mv "${torrent_path}" "${dest}" 2>/dev/null; then
    log "Triaged to ${category}: ${torrent_name} → ${dest}"
    TRIAGE_PERFORMED=true
    return 0
  else
    log "Warning: Failed to move ${torrent_name} to triage/${category}"
    return 1
  fi
}

rotate_log() {
  local log_file_stat
  log_file_stat="$(stat -f%z "${LOG_FILE}")"
  if [[ -f "${LOG_FILE}" ]] && [[ "${log_file_stat}" -gt ${MAX_LOG_SIZE} ]]; then
    mv "${LOG_FILE}" "${LOG_FILE}.old"
  fi
}

# Detect whether script was invoked by Transmission or manually
detect_invocation_mode() {
  if [[ -n "${TR_TORRENT_DIR:-}" ]] && [[ -n "${TR_TORRENT_NAME:-}" ]]; then
    INVOCATION_MODE="automated"
    log "Detected AUTOMATED mode (Transmission callback)"
  else
    INVOCATION_MODE="manual"
    log "Detected MANUAL mode (user invocation)"
  fi
}

# Prompt user for directory in manual mode
prompt_for_directory() {
  local selected_dir=""

  # In test mode, return a default directory without prompting
  if [[ "${TEST_MODE:-false}" == "true" ]]; then
    selected_dir="${HOME}/Movies/"
    log "TEST MODE: Using default directory: ${selected_dir}"
    echo "${selected_dir}"
    return 0
  fi

  # Try macOS native folder picker via osascript
  if command -v osascript &>/dev/null; then
    selected_dir=$(osascript -e 'POSIX path of (choose folder with prompt "Select media directory to process:")' 2>/dev/null || echo "")
  fi

  # Fallback to terminal prompt if osascript failed or unavailable
  if [[ -z "${selected_dir}" ]]; then
    printf 'Enter path to media directory: ' >&2
    read -r selected_dir
  fi

  # Expand tilde to home directory
  selected_dir="${selected_dir/#\~/${HOME}}"

  # Validate directory exists
  if [[ ! -d "${selected_dir}" ]]; then
    log "Error: Not a valid directory: ${selected_dir}"
    return 1
  fi

  echo "${selected_dir}"
}

validate_environment() {
  # Detect invocation mode first
  detect_invocation_mode

  # Mode-specific validation
  if [[ "${INVOCATION_MODE}" == "automated" ]]; then
    # Automated mode: Transmission must have set TR_* variables
    if [[ -z "${TR_TORRENT_DIR:-}" ]] || [[ -z "${TR_TORRENT_NAME:-}" ]]; then
      printf 'Error: Required Transmission variables not set\nTR_TORRENT_DIR: \t[%s]\nTR_TORRENT_NAME:\t[%s]\n' \
        "${TR_TORRENT_DIR:-}" "${TR_TORRENT_NAME:-}" >&2
      return 1
    fi
    log "Using Transmission directory: ${TR_TORRENT_DIR}"
  else
    # Manual mode: Prompt for directory and set TR_* variables for compatibility
    local source_dir torrent_name
    source_dir=$(prompt_for_directory) || return 1
    torrent_name=$(basename "${source_dir}")

    # Set TR_* variables so rest of script works unchanged
    export TR_TORRENT_DIR="${source_dir}"
    export TR_TORRENT_NAME="${torrent_name}"

    log "Using manual directory: ${TR_TORRENT_DIR}"
  fi

  # Common validation: Plex path must exist and be writable
  if [[ ! -d "${PLEX_MEDIA_PATH}" ]]; then
    printf 'Error: Plex media path %s does not exist\n' "${PLEX_MEDIA_PATH}" >&2
    return 1
  fi

  if [[ ! -w "${PLEX_MEDIA_PATH}" ]]; then
    printf 'Error: No write permission to %s\n' "${PLEX_MEDIA_PATH}" >&2
    return 1
  fi

  return 0
}

initialize() {
  # Read config
  if ! read_config; then
    printf 'Error: Failed to read configuration\n' >&2
    return 1
  fi

  # Check dependencies
  if ! check_dependencies; then
    printf 'Error: Missing required dependencies\n' >&2
    return 1
  fi

  return 0
}

main() {
  local main_exit_code=0

  # Validate environment variables first
  if ! validate_environment; then
    log "Error: Environment validation failed"
    main_exit_code=1
  else
    rotate_log
    log "Starting post-download processing for ${TR_TORRENT_NAME}"

    # Construct the actual torrent path
    # Automated mode: TR_TORRENT_DIR is the parent download directory,
    #   TR_TORRENT_NAME is the specific torrent within it
    # Manual mode: TR_TORRENT_DIR is already the user-selected target directory
    local torrent_path
    if [[ "${INVOCATION_MODE}" == "automated" ]]; then
      torrent_path="${TR_TORRENT_DIR}/${TR_TORRENT_NAME}"
    else
      torrent_path="${TR_TORRENT_DIR}"
    fi
    log "Torrent path: ${torrent_path}"

    if [[ ! -e "${torrent_path}" ]]; then
      log "Error: Torrent path does not exist: ${torrent_path}"
      main_exit_code=1
    else
      # Cleanup only applies to directories (skip for single-file torrents)
      if [[ -d "${torrent_path}" ]]; then
        if ! cleanup_torrent "${torrent_path}"; then
          log "Warning: Cleanup failed but continuing"
        fi
      fi

      TRIAGE_PERFORMED=false
      if ! process_media "${torrent_path}"; then
        log "Error: Media processing failed"
        main_exit_code=1
      elif [[ "${TRIAGE_PERFORMED}" == "true" ]]; then
        log "Torrent triaged (not processed) — see triage directory"
      else
        log "Processing completed successfully"
      fi
    fi
  fi

  # Send notification in manual mode
  if [[ "${INVOCATION_MODE}" == "manual" ]]; then
    if command -v terminal-notifier &>/dev/null; then
      if [[ ${main_exit_code} -eq 0 ]]; then
        terminal-notifier \
          -title "Media Processing Complete" \
          -subtitle "${TR_TORRENT_NAME}" \
          -message "Successfully processed and added to Plex" \
          -sound "Glass" 2>/dev/null || true
      else
        terminal-notifier \
          -title "Media Processing Failed" \
          -subtitle "${TR_TORRENT_NAME}" \
          -message "Check log for details: ${LOG_FILE}" \
          -sound "Basso" 2>/dev/null || true
      fi
    fi
  fi

  return "${main_exit_code}"
}

# Early initialization
TEST_MODE="${TEST_MODE:-false}"
TEST_RUNNER="${TEST_RUNNER:-false}"

# Set default values for test mode (BATS sets TEST_MODE=true)
if [[ "${TEST_MODE}" == "true" ]]; then
  PLEX_SERVER="${PLEX_SERVER:-http://localhost:32400}"
  PLEX_TOKEN="${PLEX_TOKEN:-test_token}"
  LOG_FILE="${LOG_FILE:-/tmp/transmission-test.log}"
  MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"
else
  initialize || exit 1
fi

# Entry point: BATS sets TEST_RUNNER=true to load functions without running main
if [[ "${TEST_RUNNER}" == "true" ]]; then
  :
else
  main "$@"
fi
