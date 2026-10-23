#!/usr/bin/env bats
#
# Tests for app-setup/templates/cloudflared-wrapper.sh and the
# com.cloudflare-tunnel.plist LaunchDaemon template.
#
# The wrapper exists so the tunnel token is never in a world-readable plist
# or on a command line (ps). These tests pin that: the token reaches
# cloudflared only through the TUNNEL_TOKEN environment variable, and a
# keychain miss stops the wrapper with a message instead of starting
# cloudflared without a token.
#
# Uses the TEST_RUNNER hook: TEST_RUNNER=true before sourcing skips main.
#
# Run with: bats tests/cloudflared-wrapper.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
WRAPPER_TEMPLATE="${WRAPPER_TEMPLATE:-${REPO_DIR}/app-setup/templates/cloudflared-wrapper.sh}"
PLIST_TEMPLATE="${PLIST_TEMPLATE:-${REPO_DIR}/app-setup/templates/com.cloudflare-tunnel.plist}"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR

  WRAPPER="${TEST_TMPDIR}/cloudflared-wrapper.sh"
  sed \
    -e 's|__EXTERNAL_HOSTNAME__|test.example|g' \
    -e 's|__TUNNEL_METRICS_PORT__|20241|g' \
    -e 's|__HOSTNAME_LOWER__|testhost|g' \
    "${WRAPPER_TEMPLATE}" >"${WRAPPER}"

  # A fake cloudflared that records its arguments and whether it got the
  # token through the environment.
  FAKE_CLOUDFLARED="${TEST_TMPDIR}/cloudflared"
  cat >"${FAKE_CLOUDFLARED}" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${TEST_TMPDIR}/argv"
printf '%s' "${TUNNEL_TOKEN:-}" >"${TEST_TMPDIR}/env_token"
MOCK
  chmod +x "${FAKE_CLOUDFLARED}"

  export TEST_RUNNER=true
  # shellcheck source=/dev/null
  source "${WRAPPER}"
  CLOUDFLARED_BIN="${FAKE_CLOUDFLARED}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# Replaces the keychain read. stub_token VALUE [RC]: read_tunnel_token prints
# VALUE and returns RC (default 0).
stub_token() {
  STUB_TOKEN="$1"
  STUB_TOKEN_RC="${2:-0}"
  read_tunnel_token() {
    printf '%s' "${STUB_TOKEN}"
    return "${STUB_TOKEN_RC}"
  }
}

@test "keychain miss: exits non-zero with a message, cloudflared not started" {
  stub_token '' 44

  run main
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cloudflare-tunnel-token"*"not found"* ]]
  [ ! -e "${TEST_TMPDIR}/argv" ]
}

@test "empty keychain value: exits non-zero, cloudflared not started" {
  stub_token ''

  run main
  [ "${status}" -ne 0 ]
  [ ! -e "${TEST_TMPDIR}/argv" ]
}

@test "token found: cloudflared gets it through TUNNEL_TOKEN, not argv" {
  stub_token 'secret-tunnel-token'

  run main
  [ "${status}" -eq 0 ]
  [ "$(cat "${TEST_TMPDIR}/env_token")" = "secret-tunnel-token" ]
  run grep -F 'secret-tunnel-token' "${TEST_TMPDIR}/argv"
  [ "${status}" -ne 0 ]
}

@test "token found: runs the tunnel with no autoupdate and loopback metrics" {
  stub_token 'secret-tunnel-token'

  run main
  [ "${status}" -eq 0 ]
  [ "$(tr '\n' ' ' <"${TEST_TMPDIR}/argv")" = "tunnel --no-autoupdate --metrics 127.0.0.1:20241 run " ]
}

@test "cloudflared missing: exits non-zero with a message" {
  stub_token 'secret-tunnel-token'
  export CLOUDFLARED_BIN="${TEST_TMPDIR}/does-not-exist"

  run main
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cloudflared not found"* ]]
}

@test "wrapper: reads the token from the System keychain by service and account" {
  grep -qF 'KEYCHAIN="/Library/Keychains/System.keychain"' "${WRAPPER}"
  grep -qF 'KEYCHAIN_SERVICE="cloudflare-tunnel-token"' "${WRAPPER}"
  grep -qF 'KEYCHAIN_ACCOUNT="test.example"' "${WRAPPER}"
}

# ---------------------------------------------------------------------------
# LaunchDaemon plist
# ---------------------------------------------------------------------------

render_plist() {
  sed \
    -e 's|__HOSTNAME_LOWER__|testhost|g' \
    -e 's|__OPERATOR_USERNAME__|operator|g' \
    "${PLIST_TEMPLATE}" >"${TEST_TMPDIR}/tunnel.plist"
}

@test "plist: renders to a valid plist" {
  render_plist
  plutil -lint "${TEST_TMPDIR}/tunnel.plist"
}

@test "plist: label differs from the one cloudflared service install uses" {
  render_plist
  local label
  label=$(plutil -extract Label raw "${TEST_TMPDIR}/tunnel.plist")
  [ "${label}" = "com.testhost.cloudflare-tunnel" ]
}

@test "plist: runs the wrapper and carries no token or environment" {
  render_plist
  [ "$(plutil -extract ProgramArguments.1 raw "${TEST_TMPDIR}/tunnel.plist")" = "/usr/local/bin/cloudflared-wrapper.sh" ]
  run plutil -extract EnvironmentVariables raw "${TEST_TMPDIR}/tunnel.plist"
  [ "${status}" -ne 0 ]
  # JSON conversion drops the XML comments, which name TUNNEL_TOKEN.
  local json
  json=$(plutil -convert json -o - "${TEST_TMPDIR}/tunnel.plist")
  [ -n "${json}" ]
  run grep -iF 'token' <<<"${json}"
  [ "${status}" -ne 0 ]
}

@test "plist: KeepAlive and RunAtLoad are true" {
  render_plist
  [ "$(plutil -extract KeepAlive raw "${TEST_TMPDIR}/tunnel.plist")" = "true" ]
  [ "$(plutil -extract RunAtLoad raw "${TEST_TMPDIR}/tunnel.plist")" = "true" ]
}
