#!/usr/bin/env bats
#
# Tests for configure_plex_updates in app-setup/plex-setup.sh.
# Run with: bats tests/plex-updates.bats
#
# Plex's updater runs as the operator. When it cannot write the app it asks
# for an admin password in the GUI, and Plex stays stopped until someone
# answers. Setup gives the operator the app and turns on automatic updates.
#
# The function is extracted from the script and run with sudo, chown,
# defaults and the logging helpers stubbed; each stub records its call.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/app-setup/plex-setup.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export CALLS="${TEST_TMPDIR}/calls"
  export OPERATOR_USERNAME="operator"
  export PLEX_PREFS="com.plexapp.plexmediaserver"
  touch "${CALLS}"

  # sudo drops -p PROMPT and -iu USER and runs the command. chown and
  # defaults fail when CHOWN_FAILS / DEFAULTS_FAILS is set.
  FN="${TEST_TMPDIR}/configure.sh"
  cat >"${FN}" <<'STUBS'
sudo() {
  while [[ "$1" == "-p" || "$1" == "-iu" ]]; do shift 2; done
  "$@"
}
chown() {
  echo "chown $*" >>"${CALLS}"
  [[ -z "${CHOWN_FAILS:-}" ]]
}
defaults() {
  echo "defaults $*" >>"${CALLS}"
  [[ -z "${DEFAULTS_FAILS:-}" ]]
}
log() { :; }
section() { :; }
collect_warning() { echo "collect_warning: $1" >>"${CALLS}"; }
STUBS
  sed -n '/^configure_plex_updates() {/,/^}/p' "${SETUP_SCRIPT}" >>"${FN}"
  grep -q '^configure_plex_updates() {' "${FN}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

@test "gives the operator the Plex app and sets updates to automatic" {
  run bash -c "source '${FN}'; configure_plex_updates"
  [ "$status" -eq 0 ]
  grep -qx 'chown -R operator:staff /Applications/Plex Media Server.app' "${CALLS}"
  grep -qx 'defaults write com.plexapp.plexmediaserver ButlerTaskUpdateServer -string always' "${CALLS}"
  run grep -c collect_warning "${CALLS}"
  [ "${output}" -eq 0 ]
}

@test "a failed chown warns and leaves the update setting alone" {
  CHOWN_FAILS=1 run bash -c "source '${FN}'; configure_plex_updates"
  [ "$status" -eq 1 ]
  grep -q 'collect_warning: Could not change the owner' "${CALLS}"
  run grep -c '^defaults' "${CALLS}"
  [ "${output}" -eq 0 ]
}

@test "a failed defaults write warns" {
  DEFAULTS_FAILS=1 run bash -c "source '${FN}'; configure_plex_updates"
  [ "$status" -eq 1 ]
  grep -q 'collect_warning: Could not turn on automatic Plex updates' "${CALLS}"
}

@test "main runs it after install and does not stop setup when it fails" {
  run grep -n -E '^  (install_plex|configure_plex_updates \|\| true)$' "${SETUP_SCRIPT}"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *install_plex ]]
  [[ "${lines[1]}" == *"configure_plex_updates || true" ]]
}
