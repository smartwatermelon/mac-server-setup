#!/usr/bin/env bats

# Integration tests for complete TV show processing workflow

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR, TEST_MODE provided by BATS test_helper

load ../test_helper

@test "TV workflow: detects TV show from S01E01 pattern" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/The.Show.S01E01.mkv"
  touch "${test_dir}/The.Show.S01E02.mkv"

  # Run type detection
  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"
}

@test "TV workflow: processes TV show with FileBot auto-detection" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.S01E01.mkv"

  run process_media_with_fallback "${test_dir}"

  assert_success
}

@test "TV workflow: triggers Plex scan for show library" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run trigger_plex_scan "show"

  assert_success

  run cat "${LOG_FILE}"
  assert_output_contains "Triggering Plex scan for show library" "${output}"
  assert_output_contains "/library/sections/2/refresh" "${output}"
}

@test "TV workflow: cleans up unwanted files" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.S01E01.mkv"
  touch "${test_dir}/sample.txt"
  touch "${test_dir}/info.nfo"

  # Cleanup function removes txt and nfo files
  run cleanup_torrent "${test_dir}"

  # Verify unwanted files would be removed
  run cat "${LOG_FILE}"
  assert_output_contains "Cleaning up extraneous files" "${output}"
}

@test "TV workflow: complete automated mode processing" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export TR_TORRENT_DIR="${TEST_TEMP_DIR}/download"
  export TR_TORRENT_NAME="The.Show.S01E01"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  mkdir -p "${TR_TORRENT_DIR}"
  touch "${TR_TORRENT_DIR}/The.Show.S01E01.mkv"

  # Detect invocation mode
  detect_invocation_mode

  assert_equal "automated" "${INVOCATION_MODE}"

  # Process media
  run process_media_with_fallback "${TR_TORRENT_DIR}"

  assert_success
}

@test "TV workflow: fallback chain tries TV databases in order" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.S01E01.mkv"

  # This will fail but should log the fallback chain
  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database: TheTVDB" "${output}"
  assert_output_contains "Trying TV database: TheMovieDB::TV" "${output}"
  assert_output_contains "Trying TV database: AniDB" "${output}"
}

@test "TV workflow: validates files are ready before processing" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.S01E01.mkv"

  # check_files_ready should pass for complete files
  run check_files_ready "${test_dir}" 1

  assert_success
}

@test "TV workflow: rejects files with .part marker" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.S01E01.mkv"
  touch "${test_dir}/Show.S01E01.mkv.part"

  run check_files_ready "${test_dir}" 1

  assert_failure
}

@test "TV workflow: handles case insensitive patterns" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/show.s01e01.MKV"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"
}

@test "TV workflow: logs processing steps" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.S01E01.mkv"

  process_media_with_fallback "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Starting comprehensive fallback processing" "${output}"
  assert_output_contains "Strategy 1: FileBot auto-detection" "${output}"
}
