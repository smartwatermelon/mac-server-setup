#!/usr/bin/env bats

# Integration tests for complete movie processing workflow

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR, TEST_MODE provided by BATS test_helper

load ../test_helper

@test "Movie workflow: detects movie from year pattern" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/The.Movie.2024.mkv"

  # Run type detection
  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"
}

@test "Movie workflow: handles year range 1900-2099" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Old.Movie.1950.mkv"
  touch "${test_dir}/Future.Movie.2099.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"
}

@test "Movie workflow: excludes resolution markers (2160p, 1080i)" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.2160p.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"
}

@test "Movie workflow: processes movie with FileBot auto-detection" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"

  run process_media_with_fallback "${test_dir}"

  assert_success
}

@test "Movie workflow: triggers Plex scan for movie library" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run trigger_plex_scan "movie"

  assert_success

  run cat "${LOG_FILE}"
  assert_output_contains "Triggering Plex scan for movie library" "${output}"
  assert_output_contains "/library/sections/1/refresh" "${output}"
}

@test "Movie workflow: fallback chain tries movie databases in order" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=false
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"

  # This will fail but should log the fallback chain
  try_movie_databases "${test_dir}" 2>&1 || true

  run cat "${LOG_FILE}"
  assert_output_contains "Trying movie database: TheMovieDB" "${output}"
  assert_output_contains "Trying movie database: OMDb" "${output}"
}

@test "Movie workflow: complete automated mode processing" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export TR_TORRENT_DIR="${TEST_TEMP_DIR}/download"
  export TR_TORRENT_NAME="The.Movie.2024"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  mkdir -p "${TR_TORRENT_DIR}"
  touch "${TR_TORRENT_DIR}/The.Movie.2024.mkv"

  # Detect invocation mode
  detect_invocation_mode

  assert_equal "automated" "${INVOCATION_MODE}"

  # Process media
  run process_media_with_fallback "${TR_TORRENT_DIR}"

  assert_success
}

@test "Movie workflow: validates files are ready before processing" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"

  # check_files_ready should pass for complete files
  run check_files_ready "${test_dir}" 1

  assert_success
}

@test "Movie workflow: handles multiple movie files" {
  export TEST_MODE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"
  touch "${test_dir}/Movie.2024.Extras.mp4"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"
}

@test "Movie workflow: logs processing steps" {
  export TEST_MODE=true
  export FILEBOT_TEST_OVERRIDE=true
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"

  process_media_with_fallback "${test_dir}"

  run cat "${LOG_FILE}"
  assert_output_contains "Starting comprehensive fallback processing" "${output}"
  assert_output_contains "Strategy 1: FileBot auto-detection" "${output}"
}
