#!/usr/bin/env bats

# Tests for Plex API functions (plex_make_request, verify_plex_connection, trigger_plex_scan)

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR, TEST_MODE provided by BATS test_helper

load ../test_helper

@test "plex_make_request: succeeds in TEST_MODE" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run plex_make_request "/identity"

  assert_success
}

@test "plex_make_request: logs request in TEST_MODE" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  plex_make_request "/identity"

  run cat "${LOG_FILE}"
  assert_output_contains "TEST: Would make Plex request to /identity" "${output}"
}

@test "verify_plex_connection: succeeds in TEST_MODE" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run verify_plex_connection true

  assert_success
}

@test "verify_plex_connection: logs verification in TEST_MODE" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  verify_plex_connection true

  run cat "${LOG_FILE}"
  assert_output_contains "TEST: Would verify Plex connection" "${output}"
}

@test "trigger_plex_scan: accepts 'show' type" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run trigger_plex_scan "show"

  assert_success
}

@test "trigger_plex_scan: accepts 'movie' type" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run trigger_plex_scan "movie"

  assert_success
}

@test "trigger_plex_scan: rejects invalid type" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run trigger_plex_scan "invalid"

  assert_failure
}

@test "trigger_plex_scan: logs error for invalid type" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  trigger_plex_scan "invalid" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Error: Unknown media type for Plex scan: invalid" "${output}"
}

@test "trigger_plex_scan: uses section ID 2 for shows" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  trigger_plex_scan "show"

  run cat "${LOG_FILE}"
  assert_output_contains "/library/sections/2/refresh" "${output}"
}

@test "trigger_plex_scan: uses section ID 1 for movies" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  trigger_plex_scan "movie"

  run cat "${LOG_FILE}"
  assert_output_contains "/library/sections/1/refresh" "${output}"
}

@test "trigger_plex_scan: logs scan trigger for show" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  trigger_plex_scan "show"

  run cat "${LOG_FILE}"
  assert_output_contains "Triggering Plex scan for show library" "${output}"
}

@test "trigger_plex_scan: logs scan trigger for movie" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  trigger_plex_scan "movie"

  run cat "${LOG_FILE}"
  assert_output_contains "Triggering Plex scan for movie library" "${output}"
}

@test "trigger_plex_scan: logs success message" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  trigger_plex_scan "show"

  run cat "${LOG_FILE}"
  assert_output_contains "Plex scan triggered successfully" "${output}"
}

@test "plex_make_request: accepts endpoint parameter" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  plex_make_request "/library/sections/1/refresh"

  run cat "${LOG_FILE}"
  assert_output_contains "/library/sections/1/refresh" "${output}"
}

@test "plex_make_request: handles different endpoints" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  plex_make_request "/custom/endpoint"

  run cat "${LOG_FILE}"
  assert_output_contains "/custom/endpoint" "${output}"
}
