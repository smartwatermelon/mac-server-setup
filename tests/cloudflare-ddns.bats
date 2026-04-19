#!/usr/bin/env bats
#
# Tests for cloudflare-ddns template — validates public-IP detection,
# JSON parsing, and the change-vs-no-change decision branch.
#
# Run with: bats tests/cloudflare-ddns.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE="${REPO_DIR}/app-setup/templates/cloudflare-ddns.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  export STATE_DIR="${TEST_TMPDIR}/state"
  export LOG_FILE="${STATE_DIR}/cloudflare-ddns.log"
  export STATE_FILE="${STATE_DIR}/cloudflare-ddns.state"
  mkdir -p "${STATE_DIR}"
  touch "${LOG_FILE}"

  # Substitute placeholders + re-pin STATE_DIR/LOG_FILE/STATE_FILE to the
  # test paths. The override block is appended so it wins over the defaults
  # hard-coded near the top of the template.
  local prepared="${TEST_TMPDIR}/cloudflare-ddns.sh"
  sed \
    -e 's|__HOSTNAME__|TESTHOST|g' \
    -e 's|__EXTERNAL_HOSTNAME__|test.example|g' \
    -e 's|__CLOUDFLARE_ZONE_ID__|zone123|g' \
    -e 's|__CLOUDFLARE_RECORD_ID__|rec456|g' \
    -e 's|__OPERATOR_USERNAME__|operator|g' \
    "${TEMPLATE}" >"${prepared}"

  {
    echo ""
    echo "STATE_DIR=\"${STATE_DIR}\""
    echo "LOG_FILE=\"${LOG_FILE}\""
    echo "STATE_FILE=\"${STATE_FILE}\""
  } >>"${prepared}"

  export PREPARED="${prepared}"
  export TEST_RUNNER=true

  # shellcheck source=/dev/null
  source "${prepared}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# is_ipv4 validator
# ---------------------------------------------------------------------------

@test "is_ipv4: accepts dotted-quad" {
  run is_ipv4 "192.0.2.1"
  [ "$status" -eq 0 ]
}

@test "is_ipv4: rejects empty string" {
  run is_ipv4 ""
  [ "$status" -ne 0 ]
}

@test "is_ipv4: rejects IPv6" {
  run is_ipv4 "2001:db8::1"
  [ "$status" -ne 0 ]
}

@test "is_ipv4: rejects trailing whitespace" {
  run is_ipv4 "192.0.2.1 "
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# is_public_ipv4 range filter — must reject anything we'd regret PATCHing
# into the public A record
# ---------------------------------------------------------------------------

@test "is_public_ipv4: accepts a routable address" {
  run is_public_ipv4 "67.5.105.43"
  [ "$status" -eq 0 ]
}

@test "is_public_ipv4: rejects RFC1918 10/8" {
  run is_public_ipv4 "10.0.15.4"
  [ "$status" -ne 0 ]
}

@test "is_public_ipv4: rejects RFC1918 172.16/12 boundaries" {
  run is_public_ipv4 "172.16.0.1"
  [ "$status" -ne 0 ]
  run is_public_ipv4 "172.31.255.254"
  [ "$status" -ne 0 ]
  run is_public_ipv4 "172.32.0.1"
  [ "$status" -eq 0 ]
  run is_public_ipv4 "172.15.255.254"
  [ "$status" -eq 0 ]
}

@test "is_public_ipv4: rejects RFC1918 192.168/16" {
  run is_public_ipv4 "192.168.1.1"
  [ "$status" -ne 0 ]
}

@test "is_public_ipv4: rejects loopback, link-local, CGNAT, multicast, 0/8" {
  run is_public_ipv4 "127.0.0.1"
  [ "$status" -ne 0 ]
  run is_public_ipv4 "169.254.1.1"
  [ "$status" -ne 0 ]
  run is_public_ipv4 "100.64.0.1"
  [ "$status" -ne 0 ]
  run is_public_ipv4 "224.0.0.1"
  [ "$status" -ne 0 ]
  run is_public_ipv4 "0.0.0.0"
  [ "$status" -ne 0 ]
}

@test "is_public_ipv4: rejects out-of-range octet" {
  run is_public_ipv4 "999.0.0.1"
  [ "$status" -ne 0 ]
}

@test "fetch_public_ip: rejects a provider returning a private IP" {
  curl() {
    local url="${!#}"
    case "${url}" in
      *ipify*) echo "10.0.0.1" ;;
      *ifconfig*) echo "198.51.100.7" ;;
      *) return 6 ;;
    esac
  }
  export -f curl

  run fetch_public_ip
  [ "$status" -eq 0 ]
  [ "$output" = "198.51.100.7" ]
}

# ---------------------------------------------------------------------------
# json_field parsing (covers success / nested / missing paths)
# ---------------------------------------------------------------------------

@test "json_field: emits JSON-native booleans (lowercase)" {
  run json_field '{"success": true, "errors": []}' "success"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "json_field: emits JSON-native false" {
  run json_field '{"success": false}' "success"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "json_field: extracts nested dot-path" {
  run json_field '{"result": {"content": "67.5.105.43"}}' "result.content"
  [ "$status" -eq 0 ]
  [ "$output" = "67.5.105.43" ]
}

@test "json_field: empty output on missing field" {
  run json_field '{"result": {}}' "result.content"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "json_field: empty output on invalid JSON" {
  run json_field "not json" "success"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# main: branch when public IP already matches — no PATCH should happen
# ---------------------------------------------------------------------------

@test "main: no PATCH when public IP matches current A record" {
  # Mock keychain
  read_cf_token() { echo "mock-token"; }
  # Mock public IP
  fetch_public_ip() { echo "203.0.113.10"; }
  # Mock CF GET returning matching IP
  cloudflare_get_record() {
    echo '{"success": true, "result": {"content": "203.0.113.10"}}'
  }
  # Fail loudly if PATCH is called
  cloudflare_patch_record() {
    echo "PATCH SHOULD NOT BE CALLED" >&2
    return 99
  }
  export -f read_cf_token fetch_public_ip cloudflare_get_record cloudflare_patch_record

  run main
  [ "$status" -eq 0 ]
  # Log should NOT contain 'IP change detected'
  run grep -c "IP change detected" "${LOG_FILE}"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# main: branch when public IP differs — PATCH must happen, log reflects it
# ---------------------------------------------------------------------------

@test "main: PATCH called when public IP differs" {
  read_cf_token() { echo "mock-token"; }
  fetch_public_ip() { echo "198.51.100.5"; }
  cloudflare_get_record() {
    echo '{"success": true, "result": {"content": "203.0.113.10"}}'
  }
  # Echo IP into a witness file so the test can prove PATCH was called
  cloudflare_patch_record() {
    echo "$2" >"${TEST_TMPDIR}/patched_ip"
    echo '{"success": true, "result": {"content": "'"$2"'"}}'
  }
  export -f read_cf_token fetch_public_ip cloudflare_get_record cloudflare_patch_record

  run main
  [ "$status" -eq 0 ]
  [ -f "${TEST_TMPDIR}/patched_ip" ]
  [ "$(cat "${TEST_TMPDIR}/patched_ip")" = "198.51.100.5" ]
  run grep -c "IP change detected" "${LOG_FILE}"
  [ "$output" = "1" ]
  run grep -c "cloudflare A-record updated" "${LOG_FILE}"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# main: missing keychain token → exit 1 with error log
# ---------------------------------------------------------------------------

@test "main: fails when keychain token is missing" {
  read_cf_token() { return 1; }
  export -f read_cf_token

  run main
  [ "$status" -ne 0 ]
  run grep -c "cloudflare-api-token not found" "${LOG_FILE}"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# main: public-IP fetch fails → exit 0, WARN logged, no CF calls
# ---------------------------------------------------------------------------

@test "main: public IP fetch failure is a soft-fail (warn, exit 0)" {
  read_cf_token() { echo "mock-token"; }
  fetch_public_ip() { return 1; }
  cloudflare_get_record() {
    echo "CF GET SHOULD NOT RUN" >&2
    return 99
  }
  export -f read_cf_token fetch_public_ip cloudflare_get_record

  run main
  [ "$status" -eq 0 ]
  run grep -c "could not determine public IP" "${LOG_FILE}"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# main: Cloudflare GET failure (success=false) → exit 1 with error
# ---------------------------------------------------------------------------

@test "main: cloudflare GET rejected (success:false) is a hard-fail" {
  read_cf_token() { echo "mock-token"; }
  fetch_public_ip() { echo "198.51.100.5"; }
  cloudflare_get_record() {
    echo '{"success": false, "errors": [{"code": 10000, "message": "Authentication failed"}]}'
  }
  export -f read_cf_token fetch_public_ip cloudflare_get_record

  run main
  [ "$status" -ne 0 ]
  run grep -c "cloudflare GET rejected" "${LOG_FILE}"
  [ "$output" = "1" ]
}

@test "main: cloudflare GET network failure is a soft-fail (WARN, exit 0)" {
  read_cf_token() { echo "mock-token"; }
  fetch_public_ip() { echo "198.51.100.5"; }
  # Simulate transient: empty body + nonzero exit
  cloudflare_get_record() { return 7; }
  # PATCH must not be reached
  cloudflare_patch_record() {
    echo "SHOULD NOT RUN" >&2
    return 99
  }
  export -f read_cf_token fetch_public_ip cloudflare_get_record cloudflare_patch_record

  run main
  [ "$status" -eq 0 ]
  run grep -c "cloudflare GET unreachable" "${LOG_FILE}"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# main: Cloudflare PATCH failure → exit 1, change logged but update not confirmed
# ---------------------------------------------------------------------------

@test "main: cloudflare PATCH rejected (success:false) is a hard-fail" {
  read_cf_token() { echo "mock-token"; }
  fetch_public_ip() { echo "198.51.100.5"; }
  cloudflare_get_record() {
    echo '{"success": true, "result": {"content": "203.0.113.10"}}'
  }
  cloudflare_patch_record() {
    echo '{"success": false, "errors": [{"code": 9999, "message": "Rate limited"}]}'
  }
  export -f read_cf_token fetch_public_ip cloudflare_get_record cloudflare_patch_record

  run main
  [ "$status" -ne 0 ]
  run grep -c "cloudflare PATCH rejected" "${LOG_FILE}"
  [ "$output" = "1" ]
  run grep -c "cloudflare A-record updated" "${LOG_FILE}"
  [ "$output" = "0" ]
}

@test "main: cloudflare PATCH network failure is a soft-fail (WARN, exit 0)" {
  read_cf_token() { echo "mock-token"; }
  fetch_public_ip() { echo "198.51.100.5"; }
  cloudflare_get_record() {
    echo '{"success": true, "result": {"content": "203.0.113.10"}}'
  }
  cloudflare_patch_record() { return 28; } # curl timeout exit code
  export -f read_cf_token fetch_public_ip cloudflare_get_record cloudflare_patch_record

  run main
  [ "$status" -eq 0 ]
  run grep -c "cloudflare PATCH unreachable" "${LOG_FILE}"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# fetch_public_ip: fallback chain — first-provider-bad, second-provider-good
# ---------------------------------------------------------------------------

@test "fetch_public_ip: falls through to next provider when first returns garbage" {
  # Override curl: return garbage for first provider, valid IP for second.
  curl() {
    local url="${!#}" # last positional
    case "${url}" in
      *ipify*) echo "this-is-not-an-ip" ;;
      *ifconfig*) echo "198.51.100.99" ;;
      *) return 6 ;;
    esac
  }
  export -f curl

  run fetch_public_ip
  [ "$status" -eq 0 ]
  [ "$output" = "198.51.100.99" ]
}

@test "fetch_public_ip: fails when every provider returns garbage or errors" {
  curl() {
    local url="${!#}"
    case "${url}" in
      *ipify*) echo "bogus" ;;
      *ifconfig*) return 28 ;; # curl timeout
      *icanhazip*) echo "also-bogus" ;;
      *) return 6 ;;
    esac
  }
  export -f curl

  run fetch_public_ip
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# maybe_heartbeat: log at-most-once per HEARTBEAT_INTERVAL_SECONDS
# ---------------------------------------------------------------------------

@test "maybe_heartbeat: logs when elapsed exceeds interval" {
  # Pre-populate state with last_heartbeat far in the past
  printf 'last_ip=203.0.113.10\nlast_heartbeat=1\n' >"${STATE_FILE}"

  run maybe_heartbeat "203.0.113.10"
  [ "$status" -eq 0 ]
  run grep -c "heartbeat ok" "${LOG_FILE}"
  [ "$output" = "1" ]
  # last_heartbeat should have advanced (no longer == 1)
  run grep -E '^last_heartbeat=' "${STATE_FILE}"
  [[ "$output" != "last_heartbeat=1" ]]
}

@test "maybe_heartbeat: skips when within interval" {
  # Set last_heartbeat to just now — well within 3600s window
  local recent
  recent=$(date +%s)
  printf 'last_ip=203.0.113.10\nlast_heartbeat=%s\n' "${recent}" >"${STATE_FILE}"

  run maybe_heartbeat "203.0.113.10"
  [ "$status" -eq 0 ]
  run grep -c "heartbeat ok" "${LOG_FILE}"
  [ "$output" = "0" ]
}
