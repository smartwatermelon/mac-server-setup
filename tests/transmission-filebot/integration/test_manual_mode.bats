#!/usr/bin/env bats

# Integration tests for manual invocation mode

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR, TEST_MODE provided by BATS test_helper

load ../test_helper

@test "Manual mode: detects manual mode without TR variables" {
  unset TR_TORRENT_DIR TR_TORRENT_NAME
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  detect_invocation_mode

  assert_equal "manual" "${INVOCATION_MODE}"

  run cat "${LOG_FILE}"
  assert_output_contains "Detected MANUAL mode" "${output}"
}

@test "Manual mode: detects manual mode with empty TR variables" {
  export TR_TORRENT_DIR=""
  export TR_TORRENT_NAME=""
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  detect_invocation_mode

  assert_equal "manual" "${INVOCATION_MODE}"
}

@test "Manual mode: detects manual mode with only TR_TORRENT_DIR set" {
  export TR_TORRENT_DIR="/some/path"
  unset TR_TORRENT_NAME
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  detect_invocation_mode

  assert_equal "manual" "${INVOCATION_MODE}"
}

@test "Manual mode: detects manual mode with only TR_TORRENT_NAME set" {
  unset TR_TORRENT_DIR
  export TR_TORRENT_NAME="Some.Torrent"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  detect_invocation_mode

  assert_equal "manual" "${INVOCATION_MODE}"
}

@test "Manual mode: validates files before processing" {
  export TEST_MODE=true
  export INVOCATION_MODE="manual"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"

  # In manual mode, files should be validated
  run check_files_ready "${test_dir}" 1

  assert_success
}

@test "Manual mode: rejects incomplete files in manual mode" {
  export TEST_MODE=true
  export INVOCATION_MODE="manual"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"
  touch "${test_dir}/Movie.2024.mkv.part"

  # Should fail because of .part marker
  run check_files_ready "${test_dir}" 1

  assert_failure
}

@test "Manual mode: processes media with FileBot" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export INVOCATION_MODE="manual"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"

  run process_media_with_fallback "${test_dir}"

  assert_success
}

@test "Manual mode: handles TV shows correctly" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export INVOCATION_MODE="manual"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/tv"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.S01E01.mkv"

  # Detect type
  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"

  # Process
  run process_media_with_fallback "${test_dir}"

  assert_success
}

@test "Manual mode: handles movies correctly" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export INVOCATION_MODE="manual"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"

  # Detect type
  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"

  # Process
  run process_media_with_fallback "${test_dir}"

  assert_success
}

@test "Manual mode: logs manual mode operations" {
  unset TR_TORRENT_DIR TR_TORRENT_NAME
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  detect_invocation_mode

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"

  process_media_with_fallback "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Detected MANUAL mode" "${output}"
  assert_output_contains "Starting comprehensive fallback processing" "${output}"
}
