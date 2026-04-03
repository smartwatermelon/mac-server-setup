#!/usr/bin/env bats

# Tests for error logging functions (log_filebot_error)

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR provided by BATS test_helper

load ../test_helper

@test "log_filebot_error: logs error metadata" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "FileBot error" "${test_dir}" "TheMovieDB"

  run cat "${LOG_FILE}"
  assert_output_contains "=== FILEBOT ERROR REPORT ===" "${output}"
  assert_output_contains "Exit Code: 1" "${output}"
  assert_output_contains "Database: TheMovieDB" "${output}"
  assert_output_contains "Source Directory: ${test_dir}" "${output}"
}

@test "log_filebot_error: defaults to auto-detect for database" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "FileBot error" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Database: auto-detect" "${output}"
}

@test "log_filebot_error: lists files in source directory" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/file1.mkv"
  touch "${test_dir}/file2.mp4"

  log_filebot_error 1 "FileBot error" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Files in source directory:" "${output}"
  assert_output_contains "file1.mkv" "${output}"
  assert_output_contains "file2.mp4" "${output}"
}

@test "log_filebot_error: detects connection errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "Connection timeout error" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "⚠ CONNECTION: Network/database connection issue detected" "${output}"
  assert_output_contains "Check internet connectivity" "${output}"
}

@test "log_filebot_error: detects network errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "Network unreachable" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "⚠ CONNECTION" "${output}"
}

@test "log_filebot_error: detects permission errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "Permission denied" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "⚠ PERMISSION: File/directory permission issue detected" "${output}"
  assert_output_contains "Check write permissions" "${output}"
}

@test "log_filebot_error: detects license errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "License not found" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "⚠ LICENSE: FileBot license issue detected" "${output}"
  assert_output_contains "Verify FileBot is properly licensed" "${output}"
}

@test "log_filebot_error: detects identification errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "Unable to identify media" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "⚠ IDENTIFICATION: Media identification failed" "${output}"
  assert_output_contains "Check filename follows naming conventions" "${output}"
}

@test "log_filebot_error: detects disk space errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "No space left on device" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "⚠ DISK SPACE: Insufficient disk space" "${output}"
  assert_output_contains "Check available space" "${output}"
}

@test "log_filebot_error: provides suggestions for connection errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "Connection timeout" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Suggestions:" "${output}"
  assert_output_contains "Verify database service is online" "${output}"
}

@test "log_filebot_error: provides suggestions for permission errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "Cannot write to directory" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Suggestions:" "${output}"
  assert_output_contains "Verify user has access" "${output}"
}

@test "log_filebot_error: provides suggestions for license errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "License activation failed" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Run: filebot --license to check status" "${output}"
}

@test "log_filebot_error: provides suggestions for identification errors" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "No match found for media" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "For TV: Include S##E## or ##x## pattern" "${output}"
  assert_output_contains "For Movies: Include year (YYYY)" "${output}"
}

@test "log_filebot_error: handles missing source directory" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  log_filebot_error 1 "Error" "/nonexistent/dir"

  run cat "${LOG_FILE}"
  assert_output_contains "directory does not exist" "${output}"
}

@test "log_filebot_error: handles empty source directory" {
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/empty"
  mkdir -p "${test_dir}"

  log_filebot_error 1 "Error" "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "no files found or unable to list" "${output}"
}
