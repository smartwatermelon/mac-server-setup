#!/usr/bin/env bats

# Tests for invocation mode detection (detect_invocation_mode)

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR is provided by BATS test_helper

load ../test_helper

@test "detect_invocation_mode: detects automated mode with TR_TORRENT_DIR and TR_TORRENT_NAME" {
  export TR_TORRENT_DIR="/path/to/torrent"
  export TR_TORRENT_NAME="Test.Torrent"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}" # Clear log

  detect_invocation_mode

  assert_equal "${INVOCATION_MODE}" "automated"
  run cat "${LOG_FILE}"
  assert_output_contains "Detected AUTOMATED mode" "${output}"
}

@test "detect_invocation_mode: detects manual mode without TR variables" {
  unset TR_TORRENT_DIR TR_TORRENT_NAME
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}" # Clear log

  detect_invocation_mode

  assert_equal "${INVOCATION_MODE}" "manual"
  run cat "${LOG_FILE}"
  assert_output_contains "Detected MANUAL mode" "${output}"
}

@test "detect_invocation_mode: detects manual mode with only TR_TORRENT_DIR set" {
  export TR_TORRENT_DIR="/path/to/torrent"
  unset TR_TORRENT_NAME
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}" # Clear log

  detect_invocation_mode

  assert_equal "${INVOCATION_MODE}" "manual"
  run cat "${LOG_FILE}"
  assert_output_contains "Detected MANUAL mode" "${output}"
}

@test "detect_invocation_mode: detects manual mode with only TR_TORRENT_NAME set" {
  unset TR_TORRENT_DIR
  export TR_TORRENT_NAME="Test.Torrent"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}" # Clear log

  detect_invocation_mode

  assert_equal "${INVOCATION_MODE}" "manual"
  run cat "${LOG_FILE}"
  assert_output_contains "Detected MANUAL mode" "${output}"
}

@test "detect_invocation_mode: detects manual mode with empty TR_TORRENT_DIR" {
  export TR_TORRENT_DIR=""
  export TR_TORRENT_NAME="Test.Torrent"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}" # Clear log

  detect_invocation_mode

  assert_equal "${INVOCATION_MODE}" "manual"
  run cat "${LOG_FILE}"
  assert_output_contains "Detected MANUAL mode" "${output}"
}

@test "detect_invocation_mode: detects manual mode with empty TR_TORRENT_NAME" {
  export TR_TORRENT_DIR="/path/to/torrent"
  export TR_TORRENT_NAME=""
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}" # Clear log

  detect_invocation_mode

  assert_equal "${INVOCATION_MODE}" "manual"
  run cat "${LOG_FILE}"
  assert_output_contains "Detected MANUAL mode" "${output}"
}

@test "detect_invocation_mode: sets INVOCATION_MODE variable" {
  export TR_TORRENT_DIR="/path/to/torrent"
  export TR_TORRENT_NAME="Test.Torrent"

  detect_invocation_mode

  [[ -n "${INVOCATION_MODE}" ]] || return 1
  [[ "${INVOCATION_MODE}" == "automated" || "${INVOCATION_MODE}" == "manual" ]] || return 1
}

@test "detect_invocation_mode: automated mode requires both variables" {
  # Test that BOTH variables must be non-empty for automated mode
  export TR_TORRENT_DIR="/path/to/torrent"
  export TR_TORRENT_NAME="Test.Torrent"
  detect_invocation_mode
  local mode1="${INVOCATION_MODE}"

  unset TR_TORRENT_NAME
  detect_invocation_mode
  local mode2="${INVOCATION_MODE}"

  assert_equal "${mode1}" "automated"
  assert_equal "${mode2}" "manual"
}
