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

# --- Failure classification tests ---

@test "classify_failure: detects already-in-plex from Skipped pattern" {
  local fb_output='[AUTO] Skipped [/path/to/file.mkv] because [/dest/file.mkv] already exists
Processed 0 files'
  run classify_failure "${fb_output}"
  assert_success
  assert_equal "already-in-plex" "${output}"
}

@test "classify_failure: detects already-in-plex from IMPORT pattern" {
  local fb_output='[IMPORT] Destination file already exists: /dest/file.mkv (/src/file.mkv)
Processed 0 files'
  run classify_failure "${fb_output}"
  assert_success
  assert_equal "already-in-plex" "${output}"
}

@test "classify_failure: detects no-match from zero processed" {
  local fb_output='Rename episodes using [TheMovieDB]
Lookup via [SomeShow]
Processed 0 files'
  run classify_failure "${fb_output}"
  assert_success
  assert_equal "no-match" "${output}"
}

@test "classify_failure: detects no-match from identification failure" {
  local fb_output='unable to identify media files'
  run classify_failure "${fb_output}"
  assert_success
  assert_equal "no-match" "${output}"
}

@test "classify_failure: returns failed for empty output" {
  run classify_failure ""
  assert_success
  assert_equal "failed" "${output}"
}

@test "classify_failure: returns failed for network errors" {
  local fb_output='connection timeout reaching TheTVDB'
  run classify_failure "${fb_output}"
  assert_success
  assert_equal "failed" "${output}"
}

# --- Triage function tests ---

@test "triage_failed_torrent: moves directory to correct triage category" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/TestTorrent"
  mkdir -p "${source}"
  touch "${source}/video.mkv"

  run triage_failed_torrent "${source}" "no-match" "${triage_base}"
  assert_success
  assert_dir_exists "${triage_base}/no-match/TestTorrent"
  assert_file_exists "${triage_base}/no-match/TestTorrent/video.mkv"
  assert_file_not_exists "${source}/video.mkv"
}

@test "triage_failed_torrent: moves single file to triage category" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/Movie.2024.mkv"
  mkdir -p "${BATS_TEST_TMPDIR}/pending-move"
  touch "${source}"

  run triage_failed_torrent "${source}" "already-in-plex" "${triage_base}"
  assert_success
  assert_file_exists "${triage_base}/already-in-plex/Movie.2024.mkv"
  assert_file_not_exists "${source}"
}

@test "triage_failed_torrent: creates triage directory if missing" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/Test"
  mkdir -p "${source}"
  touch "${source}/file.mkv"

  run triage_failed_torrent "${source}" "failed" "${triage_base}"
  assert_success
  assert_dir_exists "${triage_base}/failed/Test"
}

@test "triage_failed_torrent: handles name collision by appending timestamp" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/TestTorrent"
  mkdir -p "${source}" "${triage_base}/no-match/TestTorrent"
  touch "${source}/video.mkv"

  run triage_failed_torrent "${source}" "no-match" "${triage_base}"
  assert_success
  # Original source should be gone
  assert_file_not_exists "${source}/video.mkv"
}

@test "triage_failed_torrent: logs the triage action" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/TestTorrent"
  mkdir -p "${source}"
  touch "${source}/video.mkv"

  triage_failed_torrent "${source}" "no-match" "${triage_base}"
  assert_file_exists "${LOG_FILE}"
  run grep "Triaged to" "${LOG_FILE}"
  assert_success
}
