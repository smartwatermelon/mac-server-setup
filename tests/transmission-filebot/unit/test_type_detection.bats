#!/usr/bin/env bats

# Tests for media type detection (detect_media_type_heuristic)

# shellcheck disable=SC2030,SC2031,SC2154
# SC2030/SC2031: BATS runs tests in subshells, variable modifications are intentional
# SC2154: TEST_TEMP_DIR is provided by BATS test_helper

load ../test_helper

@test "detect_media_type_heuristic: identifies TV shows with S01E01 pattern" {
  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/The.Show.S01E01.mkv"
  touch "${test_dir}/The.Show.S01E02.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  # Extract last line (the actual result)
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"
}

@test "detect_media_type_heuristic: identifies TV shows with 1x01 pattern" {
  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.1x01.mkv"
  touch "${test_dir}/Show.1x02.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"
}

@test "detect_media_type_heuristic: identifies TV shows with 'season' keyword" {
  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.Season.01.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"
}

@test "detect_media_type_heuristic: identifies TV shows with 'episode' keyword" {
  local test_dir="${TEST_TEMP_DIR}/tv_show"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.Episode.01.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"
}

@test "detect_media_type_heuristic: identifies movies with year pattern" {
  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/The.Movie.2024.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"
}

@test "detect_media_type_heuristic: identifies movies with year range 1900-2099" {
  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Old.Movie.1950.mkv"
  touch "${test_dir}/New.Movie.2099.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"
}

@test "detect_media_type_heuristic: excludes resolution markers (2160p, 1080i)" {
  local test_dir="${TEST_TEMP_DIR}/movie"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.2160p.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"
}

@test "detect_media_type_heuristic: returns unknown for no media files" {
  local test_dir="${TEST_TEMP_DIR}/empty"
  mkdir -p "${test_dir}"

  run detect_media_type_heuristic "${test_dir}"

  assert_failure
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "unknown" "${result}"
}

@test "detect_media_type_heuristic: returns unknown for no recognizable patterns" {
  local test_dir="${TEST_TEMP_DIR}/no_pattern"
  mkdir -p "${test_dir}"
  touch "${test_dir}/random_file.mkv"
  touch "${test_dir}/another_file.mp4"

  run detect_media_type_heuristic "${test_dir}"

  assert_failure
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "unknown" "${result}"
}

@test "detect_media_type_heuristic: prefers TV over movie when both patterns exist" {
  local test_dir="${TEST_TEMP_DIR}/mixed"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.2024.S01E01.mkv"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"
}

@test "detect_media_type_heuristic: handles case insensitive patterns" {
  local test_dir="${TEST_TEMP_DIR}/case_test"
  mkdir -p "${test_dir}"
  touch "${test_dir}/show.s01e01.MKV"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "tv" "${result}"
}

@test "detect_media_type_heuristic: finds both mkv and mp4 files" {
  local test_dir="${TEST_TEMP_DIR}/multi_format"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Movie.2024.mkv"
  touch "${test_dir}/Movie.2024.Extras.mp4"

  # Should detect both files
  run detect_media_type_heuristic "${test_dir}"

  assert_success
  local result
  result=$(echo "${output}" | tail -1)
  assert_equal "movie" "${result}"
}

@test "find command syntax: correctly finds both mkv and mp4 files" {
  local test_dir="${TEST_TEMP_DIR}/find_test"
  mkdir -p "${test_dir}"
  touch "${test_dir}/file.mkv"
  touch "${test_dir}/file.mp4"
  touch "${test_dir}/file.avi"
  touch "${test_dir}/file.m4v"
  touch "${test_dir}/file.txt"

  # Test the corrected find syntax used in detect_media_type_heuristic
  local count
  count=$(find "${test_dir}" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.m4v" \) | wc -l | tr -d ' ')

  assert_equal "4" "${count}"
}

@test "detect_media_type_heuristic: logs pattern counts to LOG_FILE" {
  local test_dir="${TEST_TEMP_DIR}/log_test"
  mkdir -p "${test_dir}"
  touch "${test_dir}/Show.S01E01.mkv"
  export LOG_FILE="${TEST_TEMP_DIR}/test.log"
  : >"${LOG_FILE}"

  run detect_media_type_heuristic "${test_dir}"

  assert_success
  run cat "${LOG_FILE}"
  assert_output_contains "Pattern counts" "${output}"
}
