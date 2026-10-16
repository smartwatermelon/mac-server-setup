#!/usr/bin/env bats

# Tests for the alerts.email config written by transmission-filebot-setup.sh
# (#216). The setup script runs main() unconditionally, so, as in
# test_plex_section_ids.bats, only the functions between the
# "# BEGIN/END alert email config" markers are extracted and sourced.

SETUP_SCRIPT="${BATS_TEST_DIRNAME}/../../../app-setup/transmission-filebot-setup.sh"

setup() {
  command -v yq &>/dev/null || skip "yq not installed"

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  local func_file="${TEST_TMPDIR}/alert_email_config.sh"
  awk '/^# BEGIN alert email config$/{flag=1; next} /^# END alert email config$/{exit} flag' \
    "${SETUP_SCRIPT}" >"${func_file}"
  # shellcheck source=/dev/null
  source "${func_file}"
  if ! declare -f get_monitoring_email write_config &>/dev/null; then
    echo "Extraction did not define get_monitoring_email/write_config -- markers may be stale" >&2
    return 1
  fi

  export SCRIPT_DIR="${TEST_TMPDIR}/app-setup"
  mkdir -p "${SCRIPT_DIR}/config"
  export USER_CONFIG_DIR="${TEST_TMPDIR}/config"
  export USER_CONFIG="${USER_CONFIG_DIR}/config.yml"
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "${TEST_TMPDIR}"
}

@test "get_monitoring_email: reads MONITORING_EMAIL from config.conf" {
  printf 'SERVER_NAME="TEST"\nMONITORING_EMAIL="me@example.com"\n' >"${SCRIPT_DIR}/config/config.conf"
  run get_monitoring_email
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "me@example.com" ]]
}

@test "get_monitoring_email: placeholder address counts as unset" {
  printf 'MONITORING_EMAIL="your-email@example.com"\n' >"${SCRIPT_DIR}/config/config.conf"
  run get_monitoring_email
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

@test "get_monitoring_email: no config.conf prints nothing" {
  run get_monitoring_email
  [[ "${status}" -eq 0 ]]
  [[ -z "${output}" ]]
}

@test "write_config: writes alerts.email when given" {
  write_config "http://localhost:32400" "tok" "/media" "1" "2" "me@example.com" 2>/dev/null
  run yq eval '.alerts.email' "${USER_CONFIG}"
  [[ "${output}" == "me@example.com" ]]
  run yq eval '.plex.tv_section_id' "${USER_CONFIG}"
  [[ "${output}" == "2" ]]
}

@test "write_config: omits alerts without an address" {
  write_config "http://localhost:32400" "tok" "/media" "1" "2" "" 2>/dev/null
  run yq eval '.alerts' "${USER_CONFIG}"
  [[ "${output}" == "null" ]]
}
