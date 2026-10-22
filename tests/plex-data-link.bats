#!/usr/bin/env bats
#
# Tests for ensure_plex_data_link in app-setup/plex-setup.sh.
# Run with: bats tests/plex-data-link.bats
#
# On 2026-10-22 the Plex LaunchAgent started Plex with its data directory set
# to /Users/Shared/PlexMediaServer, which did not exist. Plex created a new,
# empty server there. Setup now makes that path a link to the real data.
#
# The function is extracted from the script and run with sudo, chown and the
# logging helpers stubbed, against paths in a temp directory.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/app-setup/plex-setup.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  PLEX_DATA_DIR="${TEST_TMPDIR}/operator/Library/Application Support/Plex Media Server"
  PLEX_DATA_LINK="${TEST_TMPDIR}/Shared/PlexMediaServer/Plex Media Server"
  export OPERATOR_USERNAME="operator"
  export MIGRATION_APPLIED=false
  mkdir -p "$(dirname "${PLEX_DATA_DIR}")" "$(dirname "${PLEX_DATA_LINK}")"

  # Stubs, then the function. sudo drops -p PROMPT and -u USER and runs the
  # command as this user.
  local fn="${TEST_TMPDIR}/ensure.sh"
  cat >"${fn}" <<'STUBS'
sudo() {
  while [[ "$1" == "-p" || "$1" == "-u" ]]; do shift 2; done
  "$@"
}
chown() { :; }
log() { :; }
section() { :; }
collect_error() { echo "collect_error: $1" >&2; }
check_success() { :; }
STUBS
  sed -n '/^ensure_plex_data_link() {/,/^}/p' "${SETUP_SCRIPT}" >>"${fn}"
  grep -q '^ensure_plex_data_link() {' "${fn}"
  # shellcheck source=/dev/null
  source "${fn}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

@test "fresh install: creates the data directory and the link" {
  ensure_plex_data_link
  [ -d "${PLEX_DATA_DIR}" ]
  [ -L "${PLEX_DATA_LINK}" ]
  [ "$(readlink "${PLEX_DATA_LINK}")" = "${PLEX_DATA_DIR}" ]
}

@test "existing data, no link (TILSIT before 2026-10-22): adds the link, keeps the data" {
  mkdir -p "${PLEX_DATA_DIR}"
  echo real >"${PLEX_DATA_DIR}/Preferences.xml"

  ensure_plex_data_link
  [ "$(readlink "${PLEX_DATA_LINK}")" = "${PLEX_DATA_DIR}" ]
  [ "$(cat "${PLEX_DATA_LINK}/Preferences.xml")" = "real" ]
}

@test "a correct link is left as it is" {
  mkdir -p "${PLEX_DATA_DIR}"
  ln -s "${PLEX_DATA_DIR}" "${PLEX_DATA_LINK}"

  run ensure_plex_data_link
  [ "$status" -eq 0 ]
  [ "$(readlink "${PLEX_DATA_LINK}")" = "${PLEX_DATA_DIR}" ]
}

@test "a link to the wrong place is repointed" {
  mkdir -p "${PLEX_DATA_DIR}" "${TEST_TMPDIR}/elsewhere"
  ln -s "${TEST_TMPDIR}/elsewhere" "${PLEX_DATA_LINK}"

  ensure_plex_data_link
  [ "$(readlink "${PLEX_DATA_LINK}")" = "${PLEX_DATA_DIR}" ]
  [ -d "${TEST_TMPDIR}/elsewhere" ]
}

@test "migration: the staged copy moves into the data directory, the old data is kept aside" {
  mkdir -p "${PLEX_DATA_DIR}" "${PLEX_DATA_LINK}"
  echo old >"${PLEX_DATA_DIR}/Preferences.xml"
  echo migrated >"${PLEX_DATA_LINK}/Preferences.xml"
  export MIGRATION_APPLIED=true

  ensure_plex_data_link
  [ -L "${PLEX_DATA_LINK}" ]
  [ "$(cat "${PLEX_DATA_DIR}/Preferences.xml")" = "migrated" ]
  local backups
  backups=$(find "$(dirname "${PLEX_DATA_DIR}")" -maxdepth 1 -name 'Plex Media Server.backup.*')
  [ -n "${backups}" ]
  [ "$(cat "${backups}/Preferences.xml")" = "old" ]
}

@test "a real directory with no data directory yet is adopted" {
  mkdir -p "${PLEX_DATA_LINK}"
  echo only >"${PLEX_DATA_LINK}/Preferences.xml"

  ensure_plex_data_link
  [ -L "${PLEX_DATA_LINK}" ]
  [ "$(cat "${PLEX_DATA_DIR}/Preferences.xml")" = "only" ]
}

@test "two real directories without a migration: error, and nothing is moved" {
  mkdir -p "${PLEX_DATA_DIR}" "${PLEX_DATA_LINK}"
  echo real >"${PLEX_DATA_DIR}/Preferences.xml"
  echo stray >"${PLEX_DATA_LINK}/Preferences.xml"

  run ensure_plex_data_link
  [ "$status" -eq 1 ]
  [ -d "${PLEX_DATA_LINK}" ] && [ ! -L "${PLEX_DATA_LINK}" ]
  [ "$(cat "${PLEX_DATA_DIR}/Preferences.xml")" = "real" ]
  [ "$(cat "${PLEX_DATA_LINK}/Preferences.xml")" = "stray" ]
}

@test "main runs ensure_plex_data_link before the LaunchAgent is written" {
  local link_line agent_line
  link_line=$(grep -n '^  if ! ensure_plex_data_link; then' "${SETUP_SCRIPT}" | cut -d: -f1)
  agent_line=$(grep -n '^  configure_plex_autostart$' "${SETUP_SCRIPT}" | cut -d: -f1)
  [ -n "${link_line}" ] && [ -n "${agent_line}" ]
  [ "${link_line}" -lt "${agent_line}" ]
}
