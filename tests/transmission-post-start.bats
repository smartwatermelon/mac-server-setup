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
  local guard_match apply_match guard_line apply_line
  guard_match="$(grep -nF "source \"\${GUARD_LIB}\"" "${POST_START}")"
  apply_match="$(grep -nF "apply_port \"\${pf_port}\"" "${POST_START}")"
  guard_line="${guard_match%%:*}"
  apply_line="${apply_match%%:*}"
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

# --- token acquisition (2026-10-12) -----------------------------------------
#
# PIA's legacy gtoken endpoint answered HTTP 500 "all APIs down" on five
# consecutive renewals while the v2 endpoint issued tokens. These tests drive
# get_auth_token against a stub curl whose answer is chosen per endpoint.

# Writes ${TEST_TMPDIR}/token.sh, a harness that defines get_auth_token and
# its helpers, runs it, and prints the resulting token on success.
make_token_harness() {
  local script="${TEST_TMPDIR}/token.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    grep -E '^(PIA_TOKEN_URL|PIA_TOKEN_URL_LEGACY|CURL_[A-Z_]+)=' "${POST_START}"
    printf '%s\n' 'CURL_RETRY_DELAY=0'
    printf '%s\n' 'pia_user=p1234567 pia_pass=hunter2 pf_token=""'
    sed -n '/^log() {/,/^}/p' "${POST_START}"
    sed -n '/^request_token() {/,/^}/p' "${POST_START}"
    sed -n '/^get_auth_token() {/,/^}/p' "${POST_START}"
    cat <<'RUN'
get_auth_token && echo "TOKEN=${pf_token}"
RUN
  } >"${script}"
}

# Stub curl. Per endpoint, STUB_V2 / STUB_LEGACY name a canned outcome:
#   ok      -> HTTP 200 with a token
#   down    -> HTTP 500 with PIA's "all APIs down" message
#   neterr  -> curl exits 6 with an error on stderr
make_curl_stub() {
  cat >"${TEST_TMPDIR}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALL_LOG}"
url="${*: -1}"
case "${url}" in
  */api/client/v2/token) outcome="${STUB_V2}" ;;
  */gtoken/generateToken) outcome="${STUB_LEGACY}" ;;
  *) outcome=neterr ;;
esac
case "${outcome}" in
  ok) printf '{"status":"OK","token":"tok-%s"}\n200' "${url##*/}" ;;
  down) printf '{\n    "status": "ERROR",\n    "message": "server error: all APIs down; please report bug"\n}\n500' ;;
  neterr) echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
esac
STUB
  chmod +x "${TEST_TMPDIR}/curl"
}

@test "token: uses the v2 endpoint and does not touch legacy when v2 works" {
  make_curl_stub
  make_token_harness
  STUB_V2=ok STUB_LEGACY=down run bash "${TEST_TMPDIR}/token.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOKEN=tok-token"* ]]
  run grep -c generateToken "${CALL_LOG}"
  [ "$output" -eq 0 ]
}

@test "token: v2 sends credentials as form fields, as PIA's reference does" {
  make_curl_stub
  make_token_harness
  STUB_V2=ok STUB_LEGACY=ok run bash "${TEST_TMPDIR}/token.sh"
  grep -q -- "--form username=p1234567 --form password=hunter2 .*/api/client/v2/token" "${CALL_LOG}"
}

@test "token: falls back to legacy when v2 returns an error" {
  make_curl_stub
  make_token_harness
  STUB_V2=down STUB_LEGACY=ok run bash "${TEST_TMPDIR}/token.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOKEN=tok-generateToken"* ]]
  [[ "$output" == *"(v2) returned no token: HTTP 500: server error: all APIs down"* ]]
}

@test "token: logs PIA's status and message when both endpoints fail" {
  make_curl_stub
  make_token_harness
  STUB_V2=down STUB_LEGACY=down run bash "${TEST_TMPDIR}/token.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"TOKEN="* ]]
  [[ "$output" == *"(legacy) returned no token: HTTP 500: server error: all APIs down; please report bug"* ]]
}

@test "token: logs curl's own error on a network failure" {
  make_curl_stub
  make_token_harness
  STUB_V2=neterr STUB_LEGACY=neterr run bash "${TEST_TMPDIR}/token.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"(v2) failed: curl exit 6: curl: (6) Could not resolve host"* ]]
}

@test "token: every token request retries transient failures" {
  make_curl_stub
  make_token_harness
  STUB_V2=down STUB_LEGACY=down run bash "${TEST_TMPDIR}/token.sh"
  run grep -c -- '--retry 3' "${CALL_LOG}"
  [ "$output" -eq 2 ]
}
