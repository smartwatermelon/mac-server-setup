#!/usr/bin/env bats
#
# Tests that cloudflare-ddns logs the record it updates (DDNS_RECORD_NAME),
# not the keychain account (EXTERNAL_HOSTNAME). Since the tunnel cutover the
# two differ: tilsit.vip names the token, vpn.tilsit.vip is the record.
#
# Run with: bats tests/cloudflare-ddns-record-name.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE="${REPO_DIR}/app-setup/templates/cloudflare-ddns.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  STATE_DIR="${TEST_TMPDIR}/state"
  LOG_FILE="${STATE_DIR}/cloudflare-ddns.log"
  STATE_FILE="${STATE_DIR}/cloudflare-ddns.state"
  mkdir -p "${STATE_DIR}"
  touch "${LOG_FILE}"

  local prepared="${TEST_TMPDIR}/cloudflare-ddns.sh"
  sed \
    -e 's|__EXTERNAL_HOSTNAME__|test.example|g' \
    -e 's|__CLOUDFLARE_ZONE_ID__|zone123|g' \
    -e 's|__CLOUDFLARE_RECORD_ID__|rec456|g' \
    -e 's|__DDNS_RECORD_NAME__|vpn.test.example|g' \
    -e 's|__OPERATOR_USERNAME__|operator|g' \
    "${TEMPLATE}" >"${prepared}"
  {
    echo ""
    echo "STATE_DIR=\"${STATE_DIR}\""
    echo "LOG_FILE=\"${LOG_FILE}\""
    echo "STATE_FILE=\"${STATE_FILE}\""
  } >>"${prepared}"

  export TEST_RUNNER=true
  # shellcheck source=/dev/null
  source "${prepared}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

@test "heartbeat names the updated record, not the keychain account" {
  printf 'last_ip=203.0.113.10\nlast_heartbeat=1\n' >"${STATE_FILE}"

  run maybe_heartbeat "203.0.113.10"
  [ "$status" -eq 0 ]
  run grep -c "matches vpn.test.example$" "${LOG_FILE}"
  [ "$output" = "1" ]
}
