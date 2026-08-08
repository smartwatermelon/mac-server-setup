#!/usr/bin/env bats

# Tests for file safety functions (check_files_ready, check_file_ready_quick)

load ../test_helper
# TEST_TEMP_DIR, PLEX_MEDIA_PATH, LOG_FILE are set by test_helper's setup() before each test
TEST_TEMP_DIR="${TEST_TEMP_DIR:-}"
PLEX_MEDIA_PATH="${PLEX_MEDIA_PATH:-}"
LOG_FILE="${LOG_FILE:-}"

@test "check_file_ready_quick: accepts complete file without markers" {
  local test_file="${TEST_TEMP_DIR}/complete.mkv"
  touch "${test_file}"

  run check_file_ready_quick "${test_file}"

  assert_success
}

@test "check_file_ready_quick: rejects file with .part marker" {
  local test_file="${TEST_TEMP_DIR}/incomplete.mkv"
  touch "${test_file}"
  touch "${test_file}.part"

  run check_file_ready_quick "${test_file}"

  assert_failure
}

@test "check_file_ready_quick: rejects file with .incomplete marker" {
  local test_file="${TEST_TEMP_DIR}/incomplete.mkv"
  touch "${test_file}"
  touch "${test_file}.incomplete"

  run check_file_ready_quick "${test_file}"

  assert_failure
}

@test "check_files_ready: validates directory with complete files" {
  local test_dir
  test_dir=$(create_test_media "tv")

  run check_files_ready "${test_dir}" 1

  assert_success
}

@test "check_files_ready: rejects directory with incomplete marker" {
  local test_dir
  test_dir=$(create_test_media "movie")
  create_incomplete_file "${test_dir}"

  run check_files_ready "${test_dir}" 1

  assert_failure
}

@test "check_files_ready: handles empty directory" {
  local test_dir="${TEST_TEMP_DIR}/empty"
  mkdir -p "${test_dir}"

  run check_files_ready "${test_dir}" 1

  assert_failure
}

@test "check_files_ready: validates files with stability check" {
  local test_dir
  test_dir=$(create_test_media "tv")

  # File sizes should be stable
  run check_files_ready "${test_dir}" 1

  assert_success
}

@test "discover_and_filter_media_files: finds mkv and mp4 files" {
  local test_dir="${TEST_TEMP_DIR}/mixed"
  mkdir -p "${test_dir}"
  touch "${test_dir}/file1.mkv" "${test_dir}/file2.mp4" "${test_dir}/file3.avi"

  run discover_and_filter_media_files "${test_dir}"

  assert_success
  assert_output_contains "file1.mkv" "${output}"
  assert_output_contains "file2.mp4" "${output}"
}

@test "discover_and_filter_media_files: filters incomplete files by default" {
  local test_dir="${TEST_TEMP_DIR}/mixed"
  mkdir -p "${test_dir}"
  touch "${test_dir}/complete.mkv"
  touch "${test_dir}/incomplete.mkv"
  touch "${test_dir}/incomplete.mkv.part"

  run discover_and_filter_media_files "${test_dir}" "false"

  assert_success
  # Should not contain incomplete file
  [[ "${output}" != *"incomplete.mkv"* ]] || return 1
}

@test "discover_and_filter_media_files: includes incomplete when requested" {
  local test_dir="${TEST_TEMP_DIR}/mixed"
  mkdir -p "${test_dir}"
  touch "${test_dir}/complete.mkv"
  touch "${test_dir}/incomplete.mkv"
  touch "${test_dir}/incomplete.mkv.part"

  run discover_and_filter_media_files "${test_dir}" "true"

  assert_success
  assert_output_contains "incomplete.mkv" "${output}"
}

# --- check_disk_space tests (#147) ---
# PLEX_MEDIA_PATH is created via mkdir -p in test_helper's setup(), so `df`
# always succeeds against it by default. These tests stub `df` as a real
# executable placed first in PATH (rather than a shell function shadowing
# the binary) to exercise the success, low-space, and df-failure branches
# directly.

# Writes a fake `df` executable to a per-test PATH directory and prepends
# it to PATH for the duration of the test. $1 is the script body.
stub_df() {
  local stub_dir="${TEST_TEMP_DIR}/bin"
  mkdir -p "${stub_dir}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$1"
  } >"${stub_dir}/df"
  chmod +x "${stub_dir}/df"
  PATH="${stub_dir}:${PATH}"
  export PATH
}

@test "check_disk_space: succeeds when df reports sufficient space" {
  stub_df 'printf "Filesystem 512-blocks Used Available Capacity Mounted on\n"
printf "/dev/disk1  976490568 1000 976489568   1%% %s\n" "'"${PLEX_MEDIA_PATH}"'"'

  run check_disk_space

  assert_success
}

@test "check_disk_space: fails and logs error when df reports insufficient space" {
  stub_df 'printf "Filesystem 512-blocks Used Available Capacity Mounted on\n"
printf "/dev/disk1  976490568 976489568 100   99%% %s\n" "'"${PLEX_MEDIA_PATH}"'"'

  run check_disk_space

  assert_failure
  run cat "${LOG_FILE}"
  assert_output_contains "Insufficient space on target filesystem" "${output}"
}

@test "check_disk_space: fails and logs error when df exits non-zero" {
  stub_df 'echo "df: '"${PLEX_MEDIA_PATH}"': Input/output error" >&2
exit 1'

  run check_disk_space

  assert_failure
  run cat "${LOG_FILE}"
  assert_output_contains "Unable to check disk space (df failed, exit code 1)" "${output}"
  assert_output_contains "Path may be inaccessible: ${PLEX_MEDIA_PATH}" "${output}"
}

@test "check_disk_space: df failure path does not fall through to the space comparison" {
  # Regression guard: a df failure must return before the awk-based space
  # check runs (which would otherwise operate on garbage/empty df output).
  stub_df 'exit 2'

  run check_disk_space

  assert_failure
  run cat "${LOG_FILE}"
  assert_output_contains "df failed, exit code 2" "${output}"
  [[ "${output}" != *"Insufficient space on target filesystem"* ]] || return 1
}
