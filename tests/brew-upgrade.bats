#!/usr/bin/env bats
#
# Tests for the daily brew upgrade script that setup-auto-updates.sh writes
# (a quoted heredoc, so shellcheck on the setup script never sees it).
# Run with: bats tests/brew-upgrade.bats
#
# Plex updates itself. On 2026-10-21 the daily `brew upgrade --cask` tried to
# replace the running Plex app, failed, and left a copy that blocked every
# later run. The script now skips the casks in SKIP_CASKS.
#
# The LaunchDaemon runs the script with /bin/bash (3.2), so the tests do too.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/scripts/server/setup-auto-updates.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  BREW_CALLS="${TEST_TMPDIR}/brew-calls"
  UPGRADE_SCRIPT="${TEST_TMPDIR}/brew-upgrade.sh"
  mkdir -p "${TEST_TMPDIR}/bin" "${TEST_TMPDIR}/logs"
  touch "${BREW_CALLS}"

  # The heredoc body, with placeholders filled and Homebrew's shellenv dropped
  # so the mock brew on PATH is used.
  sed -n "/<<'BREW_EOF'$/,/^BREW_EOF$/p" "${SETUP_SCRIPT}" >"${UPGRADE_SCRIPT}.raw"
  sed -e '1d;$d' -e "s|__LOG_DIR__|${TEST_TMPDIR}/logs|g" \
    -e "s|__HOSTNAME_LOWER__|testhost|g" \
    -e '/brew shellenv/d' "${UPGRADE_SCRIPT}.raw" >"${UPGRADE_SCRIPT}"
  grep -q 'brew upgrade --formula' "${UPGRADE_SCRIPT}"

  # Mock brew: logs each call; `outdated --cask` prints ${OUTDATED_CASKS},
  # and fails when OUTDATED_FAILS is set.
  cat >"${TEST_TMPDIR}/bin/brew" <<MOCK
#!/bin/bash
echo "\$*" >>"${BREW_CALLS}"
if [[ "\$1" == "outdated" ]]; then
  printf '%s' "\${OUTDATED_CASKS:-}"
  [[ -z "\${OUTDATED_FAILS:-}" ]]
fi
MOCK
  chmod +x "${TEST_TMPDIR}/bin/brew"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

run_upgrade() {
  PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" run /bin/bash "${UPGRADE_SCRIPT}"
}

@test "the generated upgrade script passes shellcheck" {
  run shellcheck -S info -s bash "${UPGRADE_SCRIPT}"
  echo "${output}"
  [ "$status" -eq 0 ]
}

@test "plex-media-server is never passed to brew upgrade --cask" {
  OUTDATED_CASKS=$'firefox\nplex-media-server\n1password-cli\n' run_upgrade
  [ "$status" -eq 0 ]
  grep -qx 'upgrade --cask firefox 1password-cli' "${BREW_CALLS}"
  run grep -c plex-media-server "${BREW_CALLS}"
  [ "${output}" -eq 0 ]
}

@test "only Plex outdated: no cask upgrade runs, and bash 3.2 does not trip on the empty list" {
  OUTDATED_CASKS=$'plex-media-server\n' run_upgrade
  [ "$status" -eq 0 ]
  run grep -c '^upgrade --cask' "${BREW_CALLS}"
  [ "${output}" -eq 0 ]
  grep -q 'No outdated casks to upgrade (skipped: plex-media-server)' "${TEST_TMPDIR}/logs/testhost-brew-upgrade.log"
}

@test "no outdated casks: no cask upgrade runs" {
  OUTDATED_CASKS="" run_upgrade
  [ "$status" -eq 0 ]
  run grep -c '^upgrade --cask' "${BREW_CALLS}"
  [ "${output}" -eq 0 ]
}

@test "a cask whose name contains a skipped name is still upgraded" {
  OUTDATED_CASKS=$'plex-media-server-beta\n' run_upgrade
  [ "$status" -eq 0 ]
  grep -qx 'upgrade --cask plex-media-server-beta' "${BREW_CALLS}"
}

@test "a failed brew outdated logs an error and upgrades no casks" {
  OUTDATED_FAILS=1 OUTDATED_CASKS=$'firefox\n' run_upgrade
  [ "$status" -eq 0 ]
  run grep -c '^upgrade --cask' "${BREW_CALLS}"
  [ "${output}" -eq 0 ]
  grep -q 'ERROR: brew outdated --cask failed' "${TEST_TMPDIR}/logs/testhost-brew-upgrade.log"
}
