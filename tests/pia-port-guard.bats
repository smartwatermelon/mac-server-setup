#!/usr/bin/env bats
#
# Tests for pia-port-guard template — validates that invalid port-forwarding
# results are refused rather than applied to Transmission.
#
# The production incident these guard against (issue #159): upstream
# update-port.sh let an empty $pf_port reach `transmission-remote -p ""`,
# setting the listen port to 0 and stopping all magnet downloads. Every
# rejection case below represents a value that must never reach Transmission.
#
# Run with: bats tests/pia-port-guard.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
GUARD="${REPO_DIR}/app-setup/templates/pia-port-guard.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR

  # Records every transmission-remote invocation so tests can assert on
  # whether a port change was actually attempted.
  export CALL_LOG="${TEST_TMPDIR}/calls.log"
  touch "${CALL_LOG}"

  # Port reported by the stub's -si output; tests override to simulate the
  # daemon's current state.
  export STUB_CURRENT_PORT="33361"

  cat >"${TEST_TMPDIR}/transmission-remote" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALL_LOG}"
for arg in "$@"; do
  if [[ "${arg}" == "-si" ]]; then
    printf '  Listen port: %s\n' "${STUB_CURRENT_PORT}"
    exit 0
  fi
done
exit 0
STUB
  chmod +x "${TEST_TMPDIR}/transmission-remote"
  export PATH="${TEST_TMPDIR}:${PATH}"

  # shellcheck source=/dev/null
  source "${GUARD}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# --- is_valid_port ---------------------------------------------------------

@test "is_valid_port accepts a typical PIA-assigned port" {
  run is_valid_port 54321
  [ "$status" -eq 0 ]
}

@test "is_valid_port accepts the range boundaries" {
  run is_valid_port 1024
  [ "$status" -eq 0 ]
  run is_valid_port 65535
  [ "$status" -eq 0 ]
}

@test "is_valid_port rejects an empty string (the production failure)" {
  run is_valid_port ""
  [ "$status" -ne 0 ]
}

@test "is_valid_port rejects a missing argument" {
  run is_valid_port
  [ "$status" -ne 0 ]
}

@test "is_valid_port rejects jq's null for a missing payload field" {
  run is_valid_port "null"
  [ "$status" -ne 0 ]
}

@test "is_valid_port rejects whitespace" {
  run is_valid_port "   "
  [ "$status" -ne 0 ]
}

@test "is_valid_port rejects non-numeric junk" {
  run is_valid_port "abc"
  [ "$status" -ne 0 ]
}

@test "is_valid_port rejects zero" {
  run is_valid_port 0
  [ "$status" -ne 0 ]
}

@test "is_valid_port rejects privileged ports" {
  run is_valid_port 80
  [ "$status" -ne 0 ]
}

@test "is_valid_port rejects ports above the 16-bit maximum" {
  run is_valid_port 65536
  [ "$status" -ne 0 ]
}

@test "is_valid_port rejects negative numbers" {
  run is_valid_port -- "-1"
  [ "$status" -ne 0 ]
}

# --- apply_port ------------------------------------------------------------
#
# Assertions that something did NOT happen are written as `run grep` plus an
# explicit status check, never as a bare `! grep ...`. POSIX exempts a
# !-negated command from `set -e`, so `! grep -q ...` cannot fail a BATS test:
# it reads like an assertion and behaves like a no-op. These tests exist to
# prove that an invalid port never reaches `transmission-remote -p`, which is
# the failure that stopped downloads for 47 hours -- an assertion that cannot
# fail is worse than none, because it looks like coverage.

@test "apply_port sets a valid port that differs from the current one" {
  export STUB_CURRENT_PORT="33361"
  run apply_port 54321 "http://localhost:9091/transmission/rpc"
  [ "$status" -eq 0 ]
  grep -q -- "-p 54321" "${CALL_LOG}"
}

@test "apply_port skips the update when the port is unchanged" {
  export STUB_CURRENT_PORT="54321"
  run apply_port 54321 "http://localhost:9091/transmission/rpc"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no change needed"* ]]
  run grep -q -- "-p 54321" "${CALL_LOG}"
  [ "$status" -ne 0 ]
}

@test "apply_port refuses an empty port and never calls -p" {
  export STUB_CURRENT_PORT="33361"
  run apply_port "" "http://localhost:9091/transmission/rpc"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSING"* ]]
  run grep -q -- " -p " "${CALL_LOG}"
  [ "$status" -ne 0 ]
}

@test "apply_port reports the preserved port when refusing" {
  export STUB_CURRENT_PORT="33361"
  run apply_port "" "http://localhost:9091/transmission/rpc"
  [[ "$output" == *"Keeping existing peer port 33361"* ]]
}

@test "apply_port warns when Transmission is already at port 0" {
  export STUB_CURRENT_PORT="0"
  run apply_port "" "http://localhost:9091/transmission/rpc"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no valid peer port"* ]]
}

@test "apply_port refuses jq null without calling -p" {
  export STUB_CURRENT_PORT="33361"
  run apply_port "null" "http://localhost:9091/transmission/rpc"
  [ "$status" -ne 0 ]
  run grep -q -- " -p " "${CALL_LOG}"
  [ "$status" -ne 0 ]
}

@test "apply_port passes auth arguments through without word splitting" {
  export STUB_CURRENT_PORT="33361"
  run apply_port 54321 "http://localhost:9091/transmission/rpc" --auth "user:pass with spaces"
  [ "$status" -eq 0 ]
  grep -q -- "--auth user:pass with spaces" "${CALL_LOG}"
}

@test "apply_port works with no auth arguments supplied" {
  export STUB_CURRENT_PORT="33361"
  run apply_port 54321 "http://localhost:9091/transmission/rpc"
  [ "$status" -eq 0 ]
  run grep -q -- "--auth" "${CALL_LOG}"
  [ "$status" -ne 0 ]
}

# --- idempotency ------------------------------------------------------------

@test "guard can be sourced twice without error" {
  # update-port.sh retries in an infinite loop and may re-source the guard.
  # readonly constants here would abort the caller under `set -e`.
  run bash -c "set -euo pipefail
    source '${GUARD}'
    source '${GUARD}'
    is_valid_port 54321"
  [ "$status" -eq 0 ]
}
