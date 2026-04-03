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
