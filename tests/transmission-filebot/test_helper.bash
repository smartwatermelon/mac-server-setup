#!/usr/bin/env bash

# BATS test helper functions and setup

# Source the main script functions
# REPO_ROOT is two levels up from tests/transmission-filebot/
export REPO_ROOT
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR="${REPO_ROOT}/app-setup/templates"

# Set TEST_RUNNER=true to prevent main() from running when sourcing
export TEST_RUNNER=true
export TEST_MODE=true

# Source transmission-done.sh to load all functions (BATS loads this at runtime)
if [[ -f "${SCRIPT_DIR}/transmission-done.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/transmission-done.sh"
fi

# Test environment setup (BATS provides BATS_TEST_DIRNAME at runtime)
export BATS_TEST_DIRNAME="${BATS_TEST_DIRNAME:-${REPO_ROOT}/tests/transmission-filebot}"
export TEST_DATA_DIR="${BATS_TEST_DIRNAME}/fixtures"
export TEST_TEMP_DIR=""

setup() {
  # Create temporary directory for test
  TEST_TEMP_DIR="$(mktemp -d)"

  # Set test environment variables
  export PLEX_MEDIA_PATH="${TEST_TEMP_DIR}/plex"
  export PLEX_SERVER="http://localhost:32400"
  export PLEX_TOKEN="test_token"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  export MAX_LOG_SIZE=10485760
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true

  # Create necessary directories
  mkdir -p "${PLEX_MEDIA_PATH}"
  mkdir -p "$(dirname "${LOG_FILE}")"
}

teardown() {
  # Clean up temporary directory
  if [[ -n "${TEST_TEMP_DIR}" ]] && [[ -d "${TEST_TEMP_DIR}" ]]; then
    rm -rf "${TEST_TEMP_DIR}"
  fi
}

# Helper function to create test media files
create_test_media() {
  local type="$1" # tv or movie
  local dir="${TEST_TEMP_DIR}/test_${type}"
  mkdir -p "${dir}"

  if [[ "${type}" == "tv" ]]; then
    touch "${dir}/The.Show.S01E01.mkv"
    touch "${dir}/The.Show.S01E02.mkv"
  else
    touch "${dir}/The.Movie.2024.mkv"
  fi

  echo "${dir}"
}

# Helper function to create incomplete file with marker
create_incomplete_file() {
  local dir="$1"
  local file="${dir}/incomplete.mkv"
  touch "${file}"
  touch "${file}.part"
  echo "${file}"
}

# Helper function to create file being written to
create_locked_file() {
  local dir="$1"
  local file="${dir}/locked.mkv"

  # Create file and open it for writing (keeps it locked)
  exec 3>"${file}"
  echo "test data" >&3

  echo "${file}"
}

# Helper function to assert file exists
assert_file_exists() {
  local file="$1"
  [[ -f "${file}" ]] || return 1
}

# Helper function to assert file does not exist
assert_file_not_exists() {
  local file="$1"
  [[ ! -f "${file}" ]] || return 1
}

# Helper function to assert directory exists
assert_dir_exists() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 1
}

# Helper function to assert exit code
# BATS stores exit code in $status when using 'run' command
assert_success() {
  [[ "${status:-$?}" -eq 0 ]] || return 1
}

assert_failure() {
  [[ "${status:-$?}" -ne 0 ]] || return 1
}

# Helper function to assert output contains string
assert_output_contains() {
  local expected="$1"
  local actual="$2"

  if [[ "${actual}" == *"${expected}"* ]]; then
    return 0
  else
    echo "Expected output to contain: '${expected}'"
    echo "Actual output: '${actual}'"
    return 1
  fi
}

# Helper function to assert variable equals value
assert_equal() {
  local expected="$1"
  local actual="$2"

  if [[ "${actual}" == "${expected}" ]]; then
    return 0
  else
    echo "Expected: '${expected}'"
    echo "Actual: '${actual}'"
    return 1
  fi
}
