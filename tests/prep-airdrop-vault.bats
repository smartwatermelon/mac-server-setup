#!/usr/bin/env bats
#
# Tests for require_onepassword_vault in prep-airdrop.sh (#265).
# Run with: bats tests/prep-airdrop-vault.bats
#
# The vault used to fall back to a real vault id when config.conf named
# none. It now has no default, and prep-airdrop.sh stops with a message that
# names the key and the config file. The function is extracted from the
# script, so no test runs the rest of prep-airdrop.sh.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
PREP="${REPO_DIR}/prep-airdrop.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  FN="${TEST_TMPDIR}/fn.sh"
  sed -n '/^require_onepassword_vault() {/,/^}/p' "${PREP}" >"${FN}"
  grep -q '^require_onepassword_vault() {' "${FN}"
  echo 'require_onepassword_vault' >>"${FN}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# check [VAR=value ...]: run the extracted function in a clean shell.
check() {
  run env -u ONEPASSWORD_VAULT CONFIG_FILE=/example/config/config.conf "$@" \
    bash "${FN}"
}

@test "the script calls the check and exits on failure" {
  grep -qx 'require_onepassword_vault || exit 1' "${PREP}"
}

@test "an unset vault fails and names the key and the config file" {
  check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ONEPASSWORD_VAULT is not set"* ]]
  [[ "${output}" == *"/example/config/config.conf"* ]]
}

@test "an empty vault fails" {
  check ONEPASSWORD_VAULT=
  [ "${status}" -eq 1 ]
}

@test "a set vault passes" {
  check ONEPASSWORD_VAULT=example-vault
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "no 26-character vault id is hard-coded in the setup scripts" {
  run grep -nE '_VAULT[A-Z_]*="[a-z0-9]{26}"' "${PREP}" "${REPO_DIR}/scripts/server/first-boot.sh"
  [ "${status}" -eq 1 ]
}
