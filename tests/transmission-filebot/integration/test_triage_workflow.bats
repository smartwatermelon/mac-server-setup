#!/usr/bin/env bats

# Integration tests for triage classify+move workflow

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR, TEST_MODE provided by BATS test_helper

load ../test_helper

@test "triage workflow: already-in-plex torrent is classified and moved" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local torrent_dir="${TEST_TEMP_DIR}/pending-move/TestShow.S01E01"
  mkdir -p "${torrent_dir}"
  touch "${torrent_dir}/video.mkv"

  local fb_output='[AUTO] Skipped [/src/video.mkv] because [/dst/video.mkv] already exists
Processed 0 files'

  local category
  category=$(classify_failure "${fb_output}")
  assert_equal "already-in-plex" "${category}"

  local triage_base="${TEST_TEMP_DIR}/triage"
  run triage_failed_torrent "${torrent_dir}" "${category}" "${triage_base}"
  assert_success
  assert_dir_exists "${triage_base}/already-in-plex/TestShow.S01E01"
}

@test "triage workflow: no-match torrent is classified and moved" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local torrent_dir="${TEST_TEMP_DIR}/pending-move/UnknownMedia"
  mkdir -p "${torrent_dir}"
  touch "${torrent_dir}/video.mkv"

  local fb_output='Rename episodes using [TheMovieDB]
Processed 0 files'

  local category
  category=$(classify_failure "${fb_output}")
  assert_equal "no-match" "${category}"

  local triage_base="${TEST_TEMP_DIR}/triage"
  run triage_failed_torrent "${torrent_dir}" "${category}" "${triage_base}"
  assert_success
  assert_dir_exists "${triage_base}/no-match/UnknownMedia"
}

@test "triage workflow: mixed already-exists and move returns already-in-plex" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local fb_output='[AUTO] Skipped [/src/ep1.mkv] because [/dst/ep1.mkv] already exists
[MOVE] from [/src/ep2.mkv] to [/dst/ep2.mkv]
Processed 1 file'
  run classify_failure "${fb_output}"
  assert_success
  assert_equal "already-in-plex" "${output}"
}
