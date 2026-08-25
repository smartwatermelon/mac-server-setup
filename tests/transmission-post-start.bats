#!/usr/bin/env bats
#
# Tests for transmission-post-start template — the PIA port forwarding manager
# that replaces the image's bundled update-port.sh.
#
# The behaviour under test is what the bundled script got wrong (issue #159):
# a port-forwarding failure must never reach transmission-remote as an empty
# or malformed port, because that sets the listen port to 0 and stops magnet
# links from resolving at all.
#
# Run with: bats tests/transmission-post-start.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
POST_START="${REPO_DIR}/app-setup/templates/transmission-post-start.sh"
GUARD="${REPO_DIR}/app-setup/templates/pia-port-guard.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  export CALL_LOG="${TEST_TMPDIR}/calls.log"
  touch "${CALL_LOG}"
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
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# --- fail-closed on a missing guard ----------------------------------------

@test "exits rather than managing the port when the guard library is absent" {
  # Without validation the script must not touch the peer port at all —
  # running unforwarded beats risking a zeroed port.
  #
  # Run the detached branch directly (PIA_PORT_DETACHED set), since the parent
  # backgrounds itself and always returns 0.
  local script="${TEST_TMPDIR}/post-start.sh"
  sed 's|GUARD_LIB="/scripts/pia-port-guard.sh"|GUARD_LIB="/nonexistent/guard.sh"|' \
    "${POST_START}" >"${script}"
  chmod +x "${script}"

  PIA_PORT_DETACHED=1 run timeout 10 bash "${script}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"guard library missing"* ]]
  [[ "$output" == *"Refusing to manage the peer port"* ]]
}

@test "does not invoke transmission-remote when the guard is absent" {
  local script="${TEST_TMPDIR}/post-start.sh"
  sed 's|GUARD_LIB="/scripts/pia-port-guard.sh"|GUARD_LIB="/nonexistent/guard.sh"|' \
    "${POST_START}" >"${script}"
  chmod +x "${script}"

  PIA_PORT_DETACHED=1 run timeout 10 bash "${script}"
  [ ! -s "${CALL_LOG}" ]
}

# --- guard integration ------------------------------------------------------

@test "the guard rejects every port the API could plausibly return as broken" {
  # shellcheck source=/dev/null
  source "${GUARD}"

  local bad
  for bad in "" "null" "0" "abc" "   " "80" "65536"; do
    run apply_port "${bad}" "http://localhost:9091/transmission/rpc"
    [ "$status" -ne 0 ]
  done

  # Nothing above should have reached transmission-remote with -p.
  run grep -q -- " -p " "${CALL_LOG}"
  [ "$status" -ne 0 ]
}

@test "the guard applies a well-formed port" {
  # shellcheck source=/dev/null
  source "${GUARD}"

  run apply_port 50454 "http://localhost:9091/transmission/rpc"
  [ "$status" -eq 0 ]
  grep -q -- "-p 50454" "${CALL_LOG}"
}

# --- static checks ----------------------------------------------------------

@test "sources the guard before defining any port-applying logic" {
  # A regression here would mean the script could call apply_port without the
  # guard having been loaded.
  local guard_line apply_line
  guard_line="$(grep -n 'source "${GUARD_LIB}"' "${POST_START}" | cut -d: -f1)"
  apply_line="$(grep -n 'apply_port "\${pf_port}"' "${POST_START}" | cut -d: -f1)"
  [ -n "${guard_line}" ]
  [ -n "${apply_line}" ]
  [ "${guard_line}" -lt "${apply_line}" ]
}

@test "never calls transmission-remote -p outside the guard" {
  # The whole point is that the guard is the only path to setting the port.
  # Comments are stripped first: the header quotes the upstream bug verbatim.
  run bash -c "grep -vE '^[[:space:]]*#' '${POST_START}' | grep -nE 'transmission-remote.*-p '"
  [ "$status" -ne 0 ]
}

@test "acquire_and_apply aborts before apply_port when a step fails" {
  # Each API step must short-circuit, so a failure can't fall through to
  # applying an unset pf_port.
  run grep -cE '^\s*(get_auth_token|get_signature|bind_port) \|\| return 1' "${POST_START}"
  [ "$output" -eq 3 ]
}

@test "does not use set -e, which would kill the long-running loop" {
  run grep -E '^set -euo pipefail' "${POST_START}"
  [ "$status" -ne 0 ]
  run grep -E '^set -uo pipefail' "${POST_START}"
  [ "$status" -eq 0 ]
}

# --- non-blocking startup ---------------------------------------------------

@test "returns immediately instead of blocking the container startup chain" {
  # The image calls this hook synchronously, with no trailing `&`. A blocking
  # loop here hangs the rest of startup and leaves the tunnel passing no
  # traffic — observed in production 2026-08-23.
  local script="${TEST_TMPDIR}/post-start.sh"
  sed -e 's|GUARD_LIB="/scripts/pia-port-guard.sh"|GUARD_LIB="/nonexistent/guard.sh"|' \
    "${POST_START}" >"${script}"
  chmod +x "${script}"

  # Without self-backgrounding this hits the timeout instead of returning.
  run timeout 8 bash "${script}"
  [ "$status" -eq 0 ]
}

@test "detached output stays attached to the container log" {
  # nohup >/dev/null would hide every message the manager emits.
  run grep -E 'setsid .* >/dev/null' "${POST_START}"
  [ "$status" -ne 0 ]
}

@test "the detached copy does not fork again" {
  run grep -c 'PIA_PORT_DETACHED' "${POST_START}"
  [ "$output" -ge 2 ]
  run grep -E 'PIA_PORT_DETACHED=1 setsid' "${POST_START}"
  [ "$status" -eq 0 ]
}

# --- startup log accuracy (#182) --------------------------------------------

@test "the startup log does not report a region it cannot see" {
  # The image's start.sh invokes this hook without exporting the container
  # environment, so OPENVPN_CONFIG is never set here. Logging
  # "region: ${OPENVPN_CONFIG:-unknown}" therefore printed "region: unknown" on
  # every start and read as a misconfiguration during the 2026-08-23 incident.
  # Strip comments first: OPENVPN_CONFIG is still named in the prose explaining
  # why it cannot be used, and that mention should not fail the test.
  run bash -c "grep -v '^[[:space:]]*#' \"${POST_START}\" | grep -c 'OPENVPN_CONFIG'"
  [ "$output" -eq 0 ]
}

@test "the startup log reports the tunnel gateway, which is derived not inherited" {
  run grep -E 'Starting PIA port forwarding manager \(tunnel gateway:' "${POST_START}"
  [ "$status" -eq 0 ]

  # The value must come from the routing table via pf_gateway, not from the
  # environment — that is the whole point of the change.
  run grep -E '^pf_gateway_or_unknown\(\)' "${POST_START}"
  [ "$status" -eq 0 ]
}

@test "pf_gateway_or_unknown yields a placeholder before the tunnel exists" {
  local script="${TEST_TMPDIR}/gw.sh"
  # Extract just the two gateway helpers and exercise them with no tun route.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    sed -n '/^pf_gateway() {/,/^}/p' "${POST_START}"
    sed -n '/^pf_gateway_or_unknown() {/,/^}/p' "${POST_START}"
    printf '%s\n' 'pf_gateway_or_unknown'
  } >"${script}"

  # `ip` is absent on macOS and returns no tun route in the sandbox either way.
  run bash "${script}"
  [ "$status" -eq 0 ]
  [ "$output" = "not yet established" ]
}
