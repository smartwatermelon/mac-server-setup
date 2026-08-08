#!/usr/bin/env bats

# Tests for rotate_log() in transmission-done.sh (#145)
#
# rotate_log() has no direct test coverage: the missing-log-file path
# (previously crash-prone — see #111/#146, which fixed rotate_log calling
# `stat -f%z` before checking the file existed) is only exercised
# implicitly by other tests that happen to call code paths touching
# LOG_FILE, never explicitly asserted here.

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR, MAX_LOG_SIZE provided by BATS test_helper

load ../test_helper

@test "rotate_log: LOG_FILE absent -- exits 0, no error, nothing created" {
  export LOG_FILE="${TEST_TEMP_DIR}/absent.log"
  rm -f "${LOG_FILE}"

  run rotate_log

  assert_success
  assert_file_not_exists "${LOG_FILE}"
  assert_file_not_exists "${LOG_FILE}.old"
}

@test "rotate_log: LOG_FILE exists below MAX_LOG_SIZE -- file remains, no .old created" {
  export LOG_FILE="${TEST_TEMP_DIR}/small.log"
  export MAX_LOG_SIZE=10485760
  printf 'a small log line\n' >"${LOG_FILE}"

  run rotate_log

  assert_success
  assert_file_exists "${LOG_FILE}"
  assert_file_not_exists "${LOG_FILE}.old"
}

@test "rotate_log: LOG_FILE exists above MAX_LOG_SIZE -- renamed to .old" {
  export LOG_FILE="${TEST_TEMP_DIR}/big.log"
  export MAX_LOG_SIZE=10
  printf 'this line is definitely more than ten bytes long\n' >"${LOG_FILE}"

  run rotate_log

  assert_success
  assert_file_not_exists "${LOG_FILE}"
  assert_file_exists "${LOG_FILE}.old"
}

@test "rotate_log: rotation preserves original content in .old" {
  export LOG_FILE="${TEST_TEMP_DIR}/big.log"
  export MAX_LOG_SIZE=10
  printf 'this line is definitely more than ten bytes long\n' >"${LOG_FILE}"

  rotate_log

  run cat "${LOG_FILE}.old"
  assert_output_contains "this line is definitely more than ten bytes long" "${output}"
}

@test "rotate_log: file exactly at MAX_LOG_SIZE is not rotated (boundary is strictly greater-than)" {
  export LOG_FILE="${TEST_TEMP_DIR}/boundary.log"
  export MAX_LOG_SIZE=20
  # Write exactly 20 bytes
  printf '12345678901234567890' >"${LOG_FILE}"
  local actual_size
  actual_size="$(stat -f%z "${LOG_FILE}")"
  [[ "${actual_size}" -eq 20 ]] || skip "test setup did not produce a 20-byte file"

  run rotate_log

  assert_success
  assert_file_exists "${LOG_FILE}"
  assert_file_not_exists "${LOG_FILE}.old"
}
