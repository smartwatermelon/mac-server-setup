#!/usr/bin/env bats
#
# Tests for two prep-airdrop.sh aborts (#249).
# Run with: bats tests/prep-airdrop-wifi.bats
#
# 1. Script-based Wi-Fi stored its password before the external keychain
#    existed, and before store_external_keychain_credential was defined.
# 2. ssh-keygen -R exits 255 when ~/.ssh/known_hosts is missing.
#
# Code is extracted from the script and run with every external command
# (security, system_profiler, ssh-keygen) stubbed as a shell function, so no
# test touches a real keychain or ~/.ssh. No test runs the whole script.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
PREP="${REPO_DIR}/prep-airdrop.sh"

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export HOME="${TEST_TMPDIR}/home"
  export OUTPUT_PATH="${TEST_TMPDIR}/out"
  export CALLS="${TEST_TMPDIR}/calls"
  mkdir -p "${HOME}/.ssh" "${OUTPUT_PATH}/config"
  : >"${CALLS}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# line_of <line>: number of the first line in prep-airdrop.sh equal to <line>.
line_of() {
  awk -v s="$1" '$0 == s { print NR; exit }' "${PREP}"
}

# --- ordering ---------------------------------------------------------------

@test "the external keychain is initialized before the Wi-Fi block stores a credential" {
  init_call=$(line_of 'init_external_keychain')
  wifi_call=$(line_of '  store_wifi_credentials')
  [ -n "${init_call}" ]
  [ -n "${wifi_call}" ]
  [ "${init_call}" -lt "${wifi_call}" ]
}

@test "the keychain functions are defined before the first call that needs them" {
  init_call=$(line_of 'init_external_keychain')
  for fn in init_external_keychain store_external_keychain_credential store_wifi_credentials; do
    def=$(line_of "${fn}() {")
    [ -n "${def}" ]
    [ "${def}" -lt "${init_call}" ]
  done
}

# --- known_hosts ------------------------------------------------------------

known_hosts_block() {
  local fn="${TEST_TMPDIR}/kh.sh"
  {
    cat <<'STUBS'
set -euo pipefail
ssh-keygen() { echo "ssh-keygen $*" >>"${CALLS}"; }
SERVER_NAME_LOWER=macmini
STUBS
    sed -n '/^if \[\[ -f .*\/\.ssh\/known_hosts" \]\]; then$/,/^fi$/p' "${PREP}"
    echo 'echo reached-end'
  } >"${fn}"
  grep -q 'ssh-keygen -R' "${fn}"
  run bash "${fn}"
}

@test "a missing known_hosts does not stop the script and skips ssh-keygen" {
  known_hosts_block
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reached-end"* ]]
  [ ! -s "${CALLS}" ]
}

@test "an existing known_hosts gets the old host key removed" {
  : >"${HOME}/.ssh/known_hosts"
  known_hosts_block
  [ "${status}" -eq 0 ]
  grep -qx 'ssh-keygen -R macmini.local' "${CALLS}"
}

# --- store_wifi_credentials -------------------------------------------------

# run_wifi <ssid> <security rc> <store rc>
# ssid "" means no current network.
run_wifi() {
  local fn="${TEST_TMPDIR}/wifi.sh"
  {
    echo 'set -euo pipefail'
    echo "STUB_SSID='$1' STUB_SECURITY_RC=$2 STUB_STORE_RC=$3"
    cat <<'STUBS'
SERVER_NAME_LOWER=macmini
system_profiler() {
  if [[ -n "${STUB_SSID}" ]]; then
    echo "      Current Network Information:"
    echo "          ${STUB_SSID}:"
  fi
  return 0
}
security() {
  echo "security $*" >>"${CALLS}"
  [[ "${STUB_SECURITY_RC}" -eq 0 ]] && echo "wifi-secret"
  return "${STUB_SECURITY_RC}"
}
store_external_keychain_credential() {
  echo "store $1 $2 $3" >>"${CALLS}"
  return "${STUB_STORE_RC}"
}
collect_error() { echo "ERROR: $1" >>"${CALLS}"; }
collect_warning() { echo "WARNING: $1" >>"${CALLS}"; }
STUBS
    sed -n '/^store_wifi_credentials() {$/,/^}$/p' "${PREP}"
    echo 'store_wifi_credentials'
    echo 'echo reached-end'
  } >"${fn}"
  grep -q '^store_wifi_credentials() {$' "${fn}"
  run bash "${fn}"
}

@test "Wi-Fi: success stores SSID:password and writes the SSID config" {
  run_wifi HomeNet 0 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reached-end"* ]]
  grep -qx 'store wifi-macmini macmini HomeNet:wifi-secret' "${CALLS}"
  grep -qx 'WIFI_SSID="HomeNet"' "${OUTPUT_PATH}/config/wifi_network.conf"
}

@test "Wi-Fi: a failed password lookup collects an error and does not stop the script" {
  run_wifi HomeNet 44 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reached-end"* ]]
  grep -qx 'ERROR: Could not retrieve WiFi password' "${CALLS}"
  run ! grep -q '^store ' "${CALLS}"
  [ ! -e "${OUTPUT_PATH}/config/wifi_network.conf" ]
}

@test "Wi-Fi: a failed store does not write the SSID config or stop the script" {
  run_wifi HomeNet 0 1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reached-end"* ]]
  [ ! -e "${OUTPUT_PATH}/config/wifi_network.conf" ]
}

@test "Wi-Fi: no current network collects a warning and skips the lookup" {
  run_wifi "" 0 0
  [ "${status}" -eq 0 ]
  grep -qx 'WARNING: Could not detect current WiFi network' "${CALLS}"
  run ! grep -q '^security ' "${CALLS}"
  [ ! -e "${OUTPUT_PATH}/config/wifi_network.conf" ]
}
