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

# --- Dynamic library section ID tests (#110) ---
# These verify trigger_plex_scan() uses PLEX_MOVIE_SECTION_ID /
# PLEX_TV_SECTION_ID when set (e.g. via read_config() from config.yml),
# rather than the legacy hardcoded 1/2. Defaults are covered by the
# "uses section ID 1/2" tests above, which rely on the fallback values
# set at script scope when config doesn't provide overrides.

@test "trigger_plex_scan: uses configured movie section ID instead of hardcoded default" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  export PLEX_MOVIE_SECTION_ID=7
  : >"${LOG_FILE}"

  trigger_plex_scan "movie"

  run cat "${LOG_FILE}"
  assert_output_contains "/library/sections/7/refresh" "${output}"
  [[ "${output}" != *"/library/sections/1/refresh"* ]] || return 1
}

@test "trigger_plex_scan: uses configured tv section ID instead of hardcoded default" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  export PLEX_TV_SECTION_ID=9
  : >"${LOG_FILE}"

  trigger_plex_scan "show"

  run cat "${LOG_FILE}"
  assert_output_contains "/library/sections/9/refresh" "${output}"
  [[ "${output}" != *"/library/sections/2/refresh"* ]] || return 1
}

@test "trigger_plex_scan: falls back to legacy hardcoded ID when config value is unset" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  # PLEX_MOVIE_SECTION_ID defaults to "1" at script scope (see
  # `PLEX_MOVIE_SECTION_ID="${PLEX_MOVIE_SECTION_ID:-1}"` near the top of
  # transmission-done.sh) when config.yml doesn't provide an override.
  : >"${LOG_FILE}"

  trigger_plex_scan "movie"

  run cat "${LOG_FILE}"
  assert_output_contains "/library/sections/1/refresh" "${output}"
}

@test "read_config: parses movie_section_id and tv_section_id via yq the same way as other plex.* fields" {
  # read_config() reads from LOCAL_CONFIG/USER_CONFIG, both readonly paths
  # fixed at script-source time, so it can't be redirected to a per-test
  # fixture here. Instead, verify the same yq parsing expression read_config
  # uses behaves as expected against a standalone fixture — this is the
  # same technique read_config relies on for every other plex.* field.
  local config_file="${TEST_TEMP_DIR}/config.yml"
  cat >"${config_file}" <<EOF
---
version: 1.0
plex:
  server: http://localhost:32400
  token: test_token
  media_path: ${PLEX_MEDIA_PATH}
  movie_section_id: 5
  tv_section_id: 6
EOF

  run "${YQ}" eval '.plex.movie_section_id' "${config_file}"
  assert_success
  assert_equal "5" "${output}"

  run "${YQ}" eval '.plex.tv_section_id' "${config_file}"
  assert_success
  assert_equal "6" "${output}"
}

@test "read_config: yq returns 'null' string for missing section ID keys (read_config's fallback trigger)" {
  local config_file="${TEST_TEMP_DIR}/config.yml"
  cat >"${config_file}" <<EOF
---
version: 1.0
plex:
  server: http://localhost:32400
  token: test_token
  media_path: ${PLEX_MEDIA_PATH}
EOF

  run "${YQ}" eval '.plex.movie_section_id' "${config_file}"
  assert_success
  assert_equal "null" "${output}"
}

@test "read_config: yq returns empty string (not 'null') for a blank scalar section ID -- both are handled by the same guard" {
  # Covers the case where transmission-filebot-setup.sh's write_config()
  # wrote the key but discovery found no value (movie_section_id: <blank>),
  # as opposed to the key being absent entirely (previous test, yq -> "null").
  # read_config()'s guard is `[[ -n "$v" ]] && [[ "$v" != "null" ]]`, which
  # must reject both an empty string AND the literal "null".
  local config_file="${TEST_TEMP_DIR}/config.yml"
  cat >"${config_file}" <<EOF
---
version: 1.0
plex:
  server: http://localhost:32400
  token: test_token
  media_path: ${PLEX_MEDIA_PATH}
  movie_section_id:
  tv_section_id:
EOF

  run "${YQ}" eval '.plex.movie_section_id' "${config_file}"
  assert_success
  assert_equal "" "${output}"
}
