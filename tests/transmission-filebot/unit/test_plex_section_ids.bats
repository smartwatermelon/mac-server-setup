#!/usr/bin/env bats

# shellcheck disable=SC2154,SC2329
# SC2154: BATS_TEST_DIRNAME is provided by the BATS runtime
# SC2329: curl() overrides below are invoked indirectly via `export -f curl`
#         and the `run` helper's subshell, not directly in this file

#
# Tests for get_plex_section_ids() in app-setup/transmission-filebot-setup.sh (#155).
#
# get_plex_section_ids() had no direct test coverage: the parsing logic that
# walks Plex's /library/sections XML response and picks the first "movie"
# and first "show" section ID was only ever exercised manually against a
# live Plex server.
#
# transmission-filebot-setup.sh is not sourceable directly in a test harness
# -- unlike transmission-done.sh (which has a TEST_RUNNER guard), it calls
# `main "$@"` unconditionally at the bottom of the file, which would start
# an interactive installation flow. Following the extraction convention
# already used by tests/podman-machine-start.bats (which extracts a heredoc
# body from its setup script rather than sourcing the whole file), this test
# extracts just the get_plex_section_ids() function body by its `{`/`}`
# boundaries and sources that in isolation.
#
# curl is mocked per-test (see tests/cloudflare-ddns.bats for the same
# pattern) to return canned Plex /library/sections XML fixtures instead of
# making a real network call. Issue #153 (curl-failure paths for the same
# function) was closed as a near-duplicate of #155; its cases are covered
# here too.

SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../../../app-setup/transmission-filebot-setup.sh"
FIXTURES_DIR="${BATS_TEST_DIRNAME}/../fixtures/plex"

setup() {
  command -v xmlstarlet &>/dev/null || skip "xmlstarlet not installed"

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Extract only the get_plex_section_ids() function definition so sourcing
  # it does not also run main() at the bottom of the real script.
  local func_file="${TEST_TMPDIR}/get_plex_section_ids.sh"
  awk '/^get_plex_section_ids\(\) \{$/{flag=1} flag{print} flag && /^}$/{exit}' \
    "${SETUP_SCRIPT}" >"${func_file}"

  if [[ ! -s "${func_file}" ]]; then
    echo "Failed to extract get_plex_section_ids() from ${SETUP_SCRIPT}" >&2
    return 1
  fi

  # shellcheck source=/dev/null
  source "${func_file}"

  # Fail loudly (not vacuously) if the awk extraction above ever produces a
  # non-empty file that doesn't actually define the function -- e.g. after
  # a future reformat of the source script changes the brace layout.
  if ! declare -f get_plex_section_ids &>/dev/null; then
    echo "Extracted file did not define get_plex_section_ids() -- awk pattern in this file may be stale" >&2
    return 1
  fi
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "${TEST_TMPDIR}"
}

# --- Success case: single movie-type section ---

@test "get_plex_section_ids: single movie section returns correct movie_section_id" {
  curl() { cat "${FIXTURES_DIR}/single_movie.xml"; }
  export -f curl

  run get_plex_section_ids "http://localhost:32400" "test_token"

  [ "$status" -eq 0 ]
  # Exact two-line output: movie_section_id populated, tv_section_id blank
  # (not populated from the movie section).
  [ "$output" = "$(printf 'movie_section_id=1\ntv_section_id=')" ]
}

# --- Multi-library case: multiple sections of different types ---

@test "get_plex_section_ids: multiple sections of different types selects correct ID per type" {
  curl() { cat "${FIXTURES_DIR}/multi_library.xml"; }
  export -f curl

  run get_plex_section_ids "http://localhost:32400" "test_token"

  [ "$status" -eq 0 ]
  [[ "$output" == *"movie_section_id=1"* ]]
  [[ "$output" == *"tv_section_id=2"* ]]
}

@test "get_plex_section_ids: multiple movie sections picks the first one found" {
  curl() { cat "${FIXTURES_DIR}/multi_movie_sections.xml"; }
  export -f curl

  run get_plex_section_ids "http://localhost:32400" "test_token"

  [ "$status" -eq 0 ]
  [[ "$output" == *"movie_section_id=1"* ]]
  [[ "$output" != *"movie_section_id=4"* ]]
}

# --- Mixed-type case: non-movie/non-show sections are ignored ---

@test "get_plex_section_ids: ignores non-movie/non-show section types" {
  curl() { cat "${FIXTURES_DIR}/mixed_types.xml"; }
  export -f curl

  run get_plex_section_ids "http://localhost:32400" "test_token"

  [ "$status" -eq 0 ]
  [[ "$output" == *"movie_section_id=3"* ]]
  [[ "$output" == *"tv_section_id=4"* ]]
  # music (id=1) and photo (id=2) sections must not leak into either field
  [[ "$output" != *"movie_section_id=1"* ]]
  [[ "$output" != *"tv_section_id=1"* ]]
  [[ "$output" != *"movie_section_id=2"* ]]
  [[ "$output" != *"tv_section_id=2"* ]]
}

@test "get_plex_section_ids: sections list with only non-movie/non-show types returns success with empty IDs" {
  curl() { cat "${FIXTURES_DIR}/only_other_types.xml"; }
  export -f curl

  run get_plex_section_ids "http://localhost:32400" "test_token"

  [ "$status" -eq 0 ]
  # Both IDs must be blank: exact two-line output, neither field populated
  # from the unrelated artist/photo sections in the fixture.
  [ "$output" = "$(printf 'movie_section_id=\ntv_section_id=')" ]
}

# --- curl failure / empty response handling (bonus, covers closed duplicate #153) ---

@test "get_plex_section_ids: curl failure returns non-zero and warns on stderr" {
  curl() { return 22; }
  export -f curl

  run get_plex_section_ids "http://localhost:32400" "test_token"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not retrieve library sections"* ]]
}

@test "get_plex_section_ids: empty response body from curl returns non-zero" {
  curl() { printf ''; }
  export -f curl

  run get_plex_section_ids "http://localhost:32400" "test_token"

  [ "$status" -ne 0 ]
}

@test "get_plex_section_ids: response with zero Directory sections returns non-zero and warns" {
  curl() { cat "${FIXTURES_DIR}/empty_sections.xml"; }
  export -f curl

  run get_plex_section_ids "http://localhost:32400" "test_token"

  [ "$status" -ne 0 ]
  [[ "$output" == *"No library sections found"* ]]
}
