#!/usr/bin/env bats

# Tests for file safety functions (check_files_ready, check_file_ready_quick)

load ../test_helper
# TEST_TEMP_DIR is set by test_helper's setup() before each test
TEST_TEMP_DIR="${TEST_TEMP_DIR:-}"

@test "check_file_ready_quick: accepts complete file without markers" {
  local test_file="${TEST_TEMP_DIR}/complete.mkv"
  touch "${test_file}"

  run check_file_ready_quick "${test_file}"

  assert_success
}

@test "check_file_ready_quick: rejects file with .part marker" {
  local test_file="${TEST_TEMP_DIR}/incomplete.mkv"
  touch "${test_file}"
  touch "${test_file}.part"

  run check_file_ready_quick "${test_file}"

  assert_failure
}

@test "check_file_ready_quick: rejects file with .incomplete marker" {
  local test_file="${TEST_TEMP_DIR}/incomplete.mkv"
  touch "${test_file}"
  touch "${test_file}.incomplete"

  run check_file_ready_quick "${test_file}"

  assert_failure
}

@test "check_files_ready: validates directory with complete files" {
  local test_dir
  test_dir=$(create_test_media "tv")

  run check_files_ready "${test_dir}" 1

  assert_success
}

@test "check_files_ready: rejects directory with incomplete marker" {
  local test_dir
  test_dir=$(create_test_media "movie")
  create_incomplete_file "${test_dir}"

  run check_files_ready "${test_dir}" 1

  assert_failure
}

@test "check_files_ready: handles empty directory" {
  local test_dir="${TEST_TEMP_DIR}/empty"
  mkdir -p "${test_dir}"

  run check_files_ready "${test_dir}" 1

  assert_failure
}

@test "check_files_ready: validates files with stability check" {
  local test_dir
  test_dir=$(create_test_media "tv")

  # File sizes should be stable
  run check_files_ready "${test_dir}" 1

  assert_success
}

@test "discover_and_filter_media_files: finds mkv and mp4 files" {
  local test_dir="${TEST_TEMP_DIR}/mixed"
  mkdir -p "${test_dir}"
  touch "${test_dir}/file1.mkv" "${test_dir}/file2.mp4" "${test_dir}/file3.avi"

  run discover_and_filter_media_files "${test_dir}"

  assert_success
  assert_output_contains "file1.mkv" "${output}"
  assert_output_contains "file2.mp4" "${output}"
}

@test "discover_and_filter_media_files: filters incomplete files by default" {
  local test_dir="${TEST_TEMP_DIR}/mixed"
  mkdir -p "${test_dir}"
  touch "${test_dir}/complete.mkv"
  touch "${test_dir}/incomplete.mkv"
  touch "${test_dir}/incomplete.mkv.part"

  run discover_and_filter_media_files "${test_dir}" "false"

  assert_success
  # Should not contain incomplete file
  [[ "${output}" != *"incomplete.mkv"* ]] || return 1
}

@test "discover_and_filter_media_files: includes incomplete when requested" {
  local test_dir="${TEST_TEMP_DIR}/mixed"
  mkdir -p "${test_dir}"
  touch "${test_dir}/complete.mkv"
  touch "${test_dir}/incomplete.mkv"
  touch "${test_dir}/incomplete.mkv.part"

  run discover_and_filter_media_files "${test_dir}" "true"

  assert_success
  assert_output_contains "incomplete.mkv" "${output}"
}
