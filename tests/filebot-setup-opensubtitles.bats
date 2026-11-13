#!/usr/bin/env bats
#
# Tests for configure_opensubtitles_login in app-setup/filebot-setup.sh (#265).
# Run with: bats tests/filebot-setup-opensubtitles.bats
#
# prep-airdrop.sh stores the OpenSubtitles item as
# opensubtitles-<SERVER_NAME_LOWER> with account <SERVER_NAME_LOWER>, and
# first-boot.sh imports it under the same names. The lookup used
# HOSTNAME_LOWER, so it missed whenever HOSTNAME_OVERRIDE was set.
#
# The function is extracted from the script. security and sudo are shell
# functions that record their arguments, so no test reads a real keychain or
# writes real defaults.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP="${REPO_DIR}/app-setup/filebot-setup.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  FN="${TEST_TMPDIR}/fn.sh"
  cat >"${FN}" <<'STUBS'
CALLS="${TEST_TMPDIR}/calls"
security() {
  echo "security $*" >>"${CALLS}"
  [[ "$1" == "find-generic-password" ]] || return 0
  # Only the stored names hold the item.
  [[ "$*" == *"-s opensubtitles-macmini -a macmini "* ]] || return 44
  echo "subuser:subpass"
}
sudo() { echo "sudo $*" >>"${CALLS}"; }
log() { :; }
check_success() { :; }
collect_error() { echo "collect_error: $1"; }
collect_warning() { echo "collect_warning: $1"; }
STUBS
  sed -n '/^configure_opensubtitles_login() {/,/^}/p' "${SETUP}" >>"${FN}"
  grep -q '^configure_opensubtitles_login() {' "${FN}"
  cat >>"${FN}" <<'RUN'
ADMINISTRATOR_PASSWORD="x"
OPERATOR_USERNAME="operator"
configure_opensubtitles_login
RUN
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# login SERVER_NAME_LOWER HOSTNAME_LOWER
login() {
  run env TEST_TMPDIR="${TEST_TMPDIR}" SERVER_NAME_LOWER="$1" HOSTNAME_LOWER="$2" bash "${FN}"
}

@test "the script derives SERVER_NAME_LOWER from SERVER_NAME" {
  cat >"${TEST_TMPDIR}/want" <<'LINE'
SERVER_NAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"
LINE
  grep -qxF -f "${TEST_TMPDIR}/want" "${SETUP}"
}

@test "HOSTNAME_OVERRIDE set: looks up the stored SERVER_NAME_LOWER names" {
  login macmini other-host
  echo "${output}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"collect_warning"* ]]
  grep -q -- "find-generic-password -s opensubtitles-macmini -a macmini -w" "${TEST_TMPDIR}/calls"
  grep -q "defaults write net.filebot.login" "${TEST_TMPDIR}/calls"
  ! grep -q "other-host" "${TEST_TMPDIR}/calls"
}

@test "no override: SERVER_NAME_LOWER and HOSTNAME_LOWER match and the lookup works" {
  login macmini macmini
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"collect_warning"* ]]
  grep -q "defaults write net.filebot.login" "${TEST_TMPDIR}/calls"
}

@test "item missing: warns and writes no login" {
  login othername othername
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"collect_warning: OpenSubtitles credentials not found"* ]]
  ! grep -q "defaults write" "${TEST_TMPDIR}/calls"
}
