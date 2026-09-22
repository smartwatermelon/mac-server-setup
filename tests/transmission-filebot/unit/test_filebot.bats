#!/usr/bin/env bats

# Tests for FileBot processing functions

# shellcheck disable=SC2030,SC2031,SC2154,SC2329
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR, TEST_MODE, FILEBOT_TEST_OVERRIDE provided by test_helper
# SC2329: run_filebot() overrides are invoked indirectly via process_media_with_autodetect

load ../test_helper

@test "run_filebot: succeeds in TEST_MODE with FILEBOT_TEST_OVERRIDE" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true

  run run_filebot -rename "/test/dir" --format "{plex}"

  assert_success
}

@test "process_media_with_autodetect: calls FileBot without --db flag" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  run process_media_with_autodetect "${test_dir}"

  assert_success
}

@test "process_media_with_autodetect: logs auto-detection attempt" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_media_with_autodetect "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Attempting FileBot auto-detection" "${output}"
}

@test "process_with_database: calls FileBot with --db flag" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  run process_with_database "${test_dir}" "TheMovieDB"

  assert_success
}

@test "process_with_database: logs database name" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_with_database "${test_dir}" "TheMovieDB"

  run cat "${LOG_FILE}"
  assert_output_contains "Attempting FileBot processing with database: TheMovieDB" "${output}"
}

@test "process_with_database: handles different database names" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_with_database "${test_dir}" "TheTVDB"

  run cat "${LOG_FILE}"
  assert_output_contains "Attempting FileBot processing with database: TheTVDB" "${output}"
}

@test "try_tv_databases: logs fallback chain" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database fallback chain" "${output}"
}

@test "try_tv_databases: tries TheTVDB first" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database: TheTVDB" "${output}"
}

@test "try_tv_databases: tries TheMovieDB::TV as fallback" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database: TheMovieDB::TV" "${output}"
}

@test "try_tv_databases: tries AniDB as last resort" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_tv_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying TV database: AniDB" "${output}"
}

@test "try_movie_databases: logs fallback chain" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_movie_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying movie database fallback chain" "${output}"
}

@test "try_movie_databases: tries TheMovieDB first" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_movie_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying movie database: TheMovieDB" "${output}"
}

@test "try_movie_databases: tries OMDb as fallback" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  try_movie_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying movie database: OMDb" "${output}"
}

@test "process_media_with_fallback: validates source directory exists" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run process_media_with_fallback "/nonexistent/directory"

  assert_failure
}

@test "process_media_with_fallback: logs error for missing directory" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  process_media_with_fallback "/nonexistent/directory" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Error: Source path does not exist" "${output}"
}

@test "process_media_with_fallback: starts with auto-detection" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_media_with_fallback "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Strategy 1: FileBot auto-detection" "${output}"
}

@test "process_media_with_fallback: logs comprehensive fallback processing" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  process_media_with_fallback "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Starting comprehensive fallback processing" "${output}"
}

@test "process_media_with_fallback: succeeds with auto-detection when FILEBOT_TEST_OVERRIDE=true" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  run process_media_with_fallback "${test_dir}"

  assert_success
}

# --- [MOVE] counting tests (bug fix: exclude failed moves) ---

@test "process_media_with_autodetect: counts successful [MOVE] lines correctly" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  # Override run_filebot to emit successful [MOVE] output
  run_filebot() {
    echo "[MOVE] from [/a/file.mkv] to [/b/file.mkv]"
    echo "Processed 1 files"
    return 0
  }

  run process_media_with_autodetect "${test_dir}"

  assert_success
  run cat "${LOG_FILE}"
  assert_output_contains "1 files moved successfully" "${output}"
}

@test "process_media_with_autodetect: failed [MOVE] lines are not counted as success" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  # Override run_filebot to emit only a failed [MOVE] line (Access Denied)
  run_filebot() {
    echo "[MOVE] from [/a/file.mkv] to [/b/file.mkv] failed due to I/O error [Access Denied]"
    echo "Processed 0 files"
    return 1
  }

  run process_media_with_autodetect "${test_dir}"

  assert_failure
  run cat "${LOG_FILE}"
  assert_output_contains "no files moved" "${output}"
}

@test "process_media_with_autodetect: mixed success and failure counts only successes" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  # Override run_filebot to emit one success and one failure
  run_filebot() {
    echo "[MOVE] from [/a/good.mkv] to [/b/good.mkv]"
    echo "[MOVE] from [/a/bad.mkv] to [/b/bad.mkv] failed due to I/O error [Access Denied]"
    echo "Processed 1 files"
    return 1
  }

  run process_media_with_autodetect "${test_dir}"

  assert_success
  run cat "${LOG_FILE}"
  assert_output_contains "1 files moved successfully" "${output}"
}

@test "process_with_database: failed [MOVE] lines are not counted as success" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"

  run_filebot() {
    echo "[MOVE] from [/a/file.mkv] to [/b/file.mkv] failed due to I/O error [Access Denied]"
    echo "Processed 0 files"
    return 1
  }

  run process_with_database "${test_dir}" "TheMovieDB"

  assert_failure
  run cat "${LOG_FILE}"
  assert_output_contains "no files moved" "${output}"
}

# --- Database order, strictness, and conflict mode ---
#
# TheMovieDB's "The Great British Bake Off" entry stops at series 7 (the BBC
# years). Auto-detection used TheMovieDB, and -non-strict let FileBot remap a
# missing season by episode title, so S17E01 "Cake Week" was filed as S04E01
# "Cake". --conflict auto then deleted the library file already in that slot.

# Record every FileBot invocation, one line per call, into ${FILEBOT_CALLS}.
# Emits a successful [MOVE] only when the call includes $1 (a --db value);
# with no argument, every call fails.
record_filebot_calls() {
  export FILEBOT_CALLS="${TEST_TEMP_DIR}/filebot_calls"
  : >"${FILEBOT_CALLS}"
  export SUCCEED_DB="${1:-}"
  run_filebot() {
    local IFS=" "
    printf '%s\n' "$*" >>"${FILEBOT_CALLS}"
    if [[ -n "${SUCCEED_DB}" && "$*" == *"--db ${SUCCEED_DB}"* ]]; then
      echo "[MOVE] from [/a/file.mkv] to [/plex/TV Shows/file.mkv]"
      return 0
    fi
    echo "Processed 0 files"
    return 1
  }
}

@test "process_media_with_fallback: TV-pattern files try TheTVDB before auto-detection" {
  export FILEBOT_TEST_OVERRIDE=false
  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/The Great British Bake Off S17E01 Cake Week 1080p.mkv"
  record_filebot_calls "TheTVDB"

  process_media_with_fallback "${test_dir}"

  run head -1 "${FILEBOT_CALLS}"
  assert_output_contains "--db TheTVDB" "${output}"
  run wc -l <"${FILEBOT_CALLS}"
  assert_equal "1" "${output//[^0-9]/}"
  run cat "${LOG_FILE}"
  assert_output_contains "Strategy 1: TV database chain" "${output}"
}

@test "process_media_with_fallback: non-TV files still start with auto-detection" {
  export FILEBOT_TEST_OVERRIDE=false
  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Some Movie 1999 1080p.mkv"
  record_filebot_calls

  process_media_with_fallback "${test_dir}" || true

  run head -1 "${FILEBOT_CALLS}"
  assert_output_not_contains "--db" "${output}"
}

@test "process_media_with_autodetect: runs strict (no -non-strict)" {
  export FILEBOT_TEST_OVERRIDE=false
  record_filebot_calls
  process_media_with_autodetect "${TEST_TEMP_DIR}" || true
  run cat "${FILEBOT_CALLS}"
  assert_output_not_contains "-non-strict" "${output}"
}

@test "process_with_database: TheMovieDB::TV runs strict" {
  export FILEBOT_TEST_OVERRIDE=false
  record_filebot_calls
  process_with_database "${TEST_TEMP_DIR}" "TheMovieDB::TV" || true
  run cat "${FILEBOT_CALLS}"
  assert_output_not_contains "-non-strict" "${output}"
}

@test "process_with_database: TheTVDB keeps -non-strict" {
  # Strict mode refuses names shared with spin-offs (e.g. "The Great British
  # Bake Off: An Extra Slice"), so TheTVDB needs -non-strict to match at all.
  export FILEBOT_TEST_OVERRIDE=false
  record_filebot_calls
  process_with_database "${TEST_TEMP_DIR}" "TheTVDB" || true
  run cat "${FILEBOT_CALLS}"
  assert_output_contains "-non-strict" "${output}"
}

@test "FileBot calls never use --conflict auto" {
  export FILEBOT_TEST_OVERRIDE=false
  record_filebot_calls
  process_media_with_autodetect "${TEST_TEMP_DIR}" || true
  process_with_database "${TEST_TEMP_DIR}" "TheTVDB" || true
  process_with_xattr "${TEST_TEMP_DIR}" || true
  preview_filebot_changes "${TEST_TEMP_DIR}" || true
  run cat "${FILEBOT_CALLS}"
  assert_output_not_contains "--conflict auto" "${output}"
  run grep -c -- "--conflict skip" "${FILEBOT_CALLS}"
  assert_equal "4" "${output}"
}

@test "process_media_with_fallback: stops at a library conflict and keeps its output" {
  export FILEBOT_TEST_OVERRIDE=false
  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show S02E03 1080p.mkv"
  export FILEBOT_CALLS="${TEST_TEMP_DIR}/filebot_calls"
  : >"${FILEBOT_CALLS}"
  run_filebot() {
    local IFS=" "
    printf '%s\n' "$*" >>"${FILEBOT_CALLS}"
    echo "[SKIP] Skipped [/a/Show S02E03.mkv] because [/plex/TV Shows/Show/Season 02/Show - S02E03.mkv] already exists"
    echo "Processed 0 files"
    return 1
  }

  local rc=0
  process_media_with_fallback "${test_dir}" || rc=$?

  assert_equal "1" "${rc}"
  run wc -l <"${FILEBOT_CALLS}"
  assert_equal "1" "${output//[^0-9]/}"
  local category
  category=$(classify_failure "${LAST_FILEBOT_OUTPUT}")
  assert_equal "already-in-plex" "${category}"
}

@test "process_media: previews TV-pattern files with TheTVDB" {
  local test_dir="${TEST_TEMP_DIR}/media"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show S02E03 1080p.mkv"
  export PREVIEW_DB_FILE="${TEST_TEMP_DIR}/preview_db"
  check_disk_space() { return 0; }
  check_files_ready() { return 0; }
  confirm_changes() { return 0; }
  process_media_with_fallback() { return 0; }
  trigger_plex_scan() { return 0; }
  preview_filebot_changes() {
    printf '%s' "${2:-}" >"${PREVIEW_DB_FILE}"
    LAST_PREVIEW_OUTPUT="[TEST] x"
    return 0
  }

  process_media "${test_dir}"

  local preview_db
  preview_db=$(<"${PREVIEW_DB_FILE}")
  assert_equal "TheTVDB" "${preview_db}"
}

@test "preview_filebot_changes: keeps conflict output when preview fails" {
  # Preview failures are classified from LAST_PREVIEW_OUTPUT. It used to be set
  # only on success, so a duplicate caught at preview (the normal case with
  # --conflict skip) was triaged to failed/ instead of already-in-plex/.
  export FILEBOT_TEST_OVERRIDE=false
  LAST_PREVIEW_OUTPUT=""
  run_filebot() {
    echo "[SKIP] Skipped [/a/Show S02E03.mkv] because [/plex/TV Shows/Show/Season 02/Show - S02E03.mkv] already exists"
    echo "Processed 0 files"
    return 1
  }

  local rc=0
  preview_filebot_changes "${TEST_TEMP_DIR}" "TheTVDB" || rc=$?

  assert_equal "1" "${rc}"
  local category
  category=$(classify_failure "${LAST_PREVIEW_OUTPUT}")
  assert_equal "already-in-plex" "${category}"
}
