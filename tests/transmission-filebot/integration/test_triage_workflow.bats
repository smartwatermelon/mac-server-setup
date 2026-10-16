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

# --- "could not process" email (#216) ---

# Run process_media in automated mode on a torrent whose preview fails with
# FileBot output $1, recording every alert_send call.
run_failed_preview() {
  export PREVIEW_OUT="$1"
  export INVOCATION_MODE=automated
  export TR_TORRENT_DIR="${TEST_TEMP_DIR}/pending-move"
  export ALERT_CALLS="${TEST_TEMP_DIR}/alert_calls"
  : >"${ALERT_CALLS}"
  mkdir -p "${TR_TORRENT_DIR}/Some.Torrent.1989"
  touch "${TR_TORRENT_DIR}/Some.Torrent.1989/video.mkv"
  check_disk_space() { return 0; }
  check_files_ready() { return 0; }
  preview_filebot_changes() {
    export LAST_PREVIEW_OUTPUT="${PREVIEW_OUT}"
    return 1
  }
  alert_send() {
    printf 'TO=%s\nSUBJECT=%s\nBODY=%s\n' "${MONITORING_EMAIL}" "$1" "$2" >>"${ALERT_CALLS}"
    return "${ALERT_RC:-0}"
  }
  PROCESS_RC=0
  process_media "${TR_TORRENT_DIR}/Some.Torrent.1989" || PROCESS_RC=$?
}

@test "triage email: a year-guard rejection emails the reason" {
  export ALERT_EMAIL="me@example.com"
  run_failed_preview "[TEST] from [/a/x.1989.avi] to [/m/Movies/X (1988)/X (1988).avi]
${YEAR_MISMATCH_MARKER} TheMovieDB: x.1989.avi says 1989, match is 1988 (/m/Movies/X (1988)/X (1988).avi)"

  assert_equal "0" "${PROCESS_RC}"
  assert_dir_exists "${TEST_TEMP_DIR}/triage/no-match/Some.Torrent.1989"
  run cat "${ALERT_CALLS}"
  assert_output_contains "TO=me@example.com" "${output}"
  assert_output_contains "could not identify: Some.Torrent.1989" "${output}"
  assert_output_contains "says 1989, match is 1988" "${output}"
  assert_output_contains "triage/no-match" "${output}"
}

@test "triage email: a failed torrent is emailed" {
  export ALERT_EMAIL="me@example.com"
  run_failed_preview "java.net.UnknownHostException: api.themoviedb.org"

  assert_dir_exists "${TEST_TEMP_DIR}/triage/failed/Some.Torrent.1989"
  run cat "${ALERT_CALLS}"
  assert_output_contains "failed to process: Some.Torrent.1989" "${output}"
  assert_output_contains "UnknownHostException" "${output}"
}

@test "triage email: already-in-plex sends no email" {
  export ALERT_EMAIL="me@example.com"
  run_failed_preview "[SKIP] Skipped [/a/x.mkv] because [/m/x.mkv] already exists"

  assert_dir_exists "${TEST_TEMP_DIR}/triage/already-in-plex/Some.Torrent.1989"
  run cat "${ALERT_CALLS}"
  assert_equal "" "${output}"
}

@test "triage email: no alerts.email means no email" {
  export ALERT_EMAIL=""
  run_failed_preview "Processed 0 files"

  assert_dir_exists "${TEST_TEMP_DIR}/triage/no-match/Some.Torrent.1989"
  run cat "${ALERT_CALLS}"
  assert_equal "" "${output}"
  run cat "${LOG_FILE}"
  assert_output_contains "No alerts.email in config" "${output}"
}

@test "triage email: a mail failure does not change the result" {
  export ALERT_EMAIL="me@example.com"
  export ALERT_RC=1
  run_failed_preview "Processed 0 files"

  assert_equal "0" "${PROCESS_RC}"
  assert_dir_exists "${TEST_TEMP_DIR}/triage/no-match/Some.Torrent.1989"
  run cat "${LOG_FILE}"
  assert_output_contains "email about no-match failed" "${output}"
}
