#!/usr/bin/env bats
#
# Tests for app-setup/templates/tunnel-watchdog.sh — the Cloudflare Tunnel
# health watchdog (issue #237, plan Task 8 of the G2 build).
#
# When cloudflared loses its edge connections or stops, the site is down for
# every visitor and nothing else on the server notices. These tests pin:
#
#   1. A ready tunnel (200 from /ready) sends no email.
#   2. A 503 or no answer counts as a failure; the alert waits for a streak
#      of FAILURE_THRESHOLD, so a reconnect does not page.
#   3. One alert per outage, then one recovery email.
#   4. --check never sends email or changes state.
#   5. The setup script substitutes every placeholder in the template.
#
# The watchdog runs end to end against a curl mock in a fake Homebrew prefix
# (the pattern from access-policy-watchdog.bats).
#
# Run with: bats tests/tunnel-watchdog.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE="${TEMPLATE:-${REPO_DIR}/app-setup/templates/tunnel-watchdog.sh}"
SETUP_SCRIPT="${REPO_DIR}/app-setup/tunnel-watchdog-setup.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  FAKE_BREW="${TEST_TMPDIR}/brew"
  MOCK_BIN_DIR="${FAKE_BREW}/bin"
  mkdir -p "${MOCK_BIN_DIR}"

  export HOME="${TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.config/msmtp" "${HOME}/.local/state" "${HOME}/.local/lib"
  touch "${HOME}/.config/msmtp/config"
  cp "${REPO_DIR}/app-setup/templates/alert-lib.sh" "${HOME}/.local/lib/alert-lib.sh"

  CONFIG_DIR="${HOME}/.config/tunnel-watchdog"

  export MAIL_LOG="${TEST_TMPDIR}/mail.log"
  : >"${MAIL_LOG}"

  set_ready 200 '{"status":200,"readyConnections":4,"connectorId":"c-1"}'

  write_curl_mock
  write_msmtp_mock
  render_template
  # Also first on the test's own PATH, so a watchdog that does not set PATH
  # still gets the mock.
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

render_template() {
  WATCHDOG="${TEST_TMPDIR}/tunnel-watchdog.sh"
  sed \
    -e 's|__HOSTNAME__|TESTHOST|g' \
    -e 's|__HOSTNAME_LOWER__|testhost|g' \
    -e 's|__OPERATOR_USERNAME__|opuser|g' \
    -e 's|__MONITORING_EMAIL__|ops@example.com|g' \
    -e 's|__EXTERNAL_HOSTNAME__|test.example|g' \
    -e 's|__TUNNEL_METRICS_PORT__|29999|g' \
    -e "s|HOMEBREW_PREFIX=\"[^\"]*\"|HOMEBREW_PREFIX=\"${FAKE_BREW}\"|" \
    "${TEMPLATE}" >"${WATCHDOG}"
  chmod +x "${WATCHDOG}"
}

# set_ready HTTP_CODE BODY: what the next /ready requests return.
set_ready() {
  echo "$1" >"${TEST_TMPDIR}/ready_code"
  printf '%s' "$2" >"${TEST_TMPDIR}/ready_body"
  rm -f "${TEST_TMPDIR}/curl_fail"
}

# No listener: curl exits 7 (could not connect).
set_refused() {
  touch "${TEST_TMPDIR}/curl_fail"
}

write_curl_mock() {
  cat >"${MOCK_BIN_DIR}/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_TMPDIR}/curl_argv"
if [[ -e "${TEST_TMPDIR}/curl_fail" ]]; then
  exit 7
fi
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [[ "${url}" != "http://127.0.0.1:29999/ready" ]]; then
  echo "unexpected URL ${url}" >&2
  exit 22
fi
cp "${TEST_TMPDIR}/ready_body" "${out}"
printf '%s' "$(cat "${TEST_TMPDIR}/ready_code")"
MOCK
  chmod +x "${MOCK_BIN_DIR}/curl"
}

write_msmtp_mock() {
  cat >"${MOCK_BIN_DIR}/msmtp" <<'MOCK'
#!/usr/bin/env bash
{ echo "=== MAIL ==="; cat; } >>"${MAIL_LOG}"
MOCK
  chmod +x "${MOCK_BIN_DIR}/msmtp"
}

# /bin/bash, as the LaunchAgent runs it: on macOS that is bash 3.2.
run_cycle() {
  /bin/bash "${WATCHDOG}"
}

run_check() {
  /bin/bash "${WATCHDOG}" --check
}

mail_count() {
  grep -c '^=== MAIL ===$' "${MAIL_LOG}" || true
}

state_field() {
  jq -r "$1" "${CONFIG_DIR}/state.json"
}

watchdog_log() {
  cat "${HOME}/.local/state/tunnel-watchdog.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Ready
# ---------------------------------------------------------------------------

@test "ready: no email, OK heartbeat with the connection count" {
  run run_cycle
  [ "${status}" -eq 0 ]
  [ "$(mail_count || true)" -eq 0 ]
  [ "$(state_field '.failures' || true)" = "0" ]
  grep -q "OK: tunnel ready, 4 connections to Cloudflare" <<<"$(watchdog_log || true)"
}

@test "ready: the heartbeat is logged once an hour, not every cycle" {
  run_cycle
  run_cycle
  [ "$(grep -c 'OK: tunnel ready' <<<"$(watchdog_log || true)" || true)" -eq 1 ]
}

@test "ready: --check prints OK and exits 0" {
  run run_check
  [ "${status}" -eq 0 ]
  [[ "${output}" == "OK: tunnel ready, 4 connections to Cloudflare" ]]
}

# ---------------------------------------------------------------------------
# Not ready
# ---------------------------------------------------------------------------

@test "503: below the threshold, failures counted and no email" {
  set_ready 503 '{"status":503,"readyConnections":0,"connectorId":"c-1"}'
  run_cycle
  run_cycle
  [ "$(mail_count || true)" -eq 0 ]
  [ "$(state_field '.failures' || true)" = "2" ]
  grep -q "WARNING: check failed (2/3).*HTTP 503 with 0 ready connections" <<<"$(watchdog_log || true)"
}

@test "503: the third failure sends one alert" {
  set_ready 503 '{"status":503,"readyConnections":0,"connectorId":"c-1"}'
  run_cycle
  run_cycle
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] Cloudflare Tunnel for test.example is down" "${MAIL_LOG}"
  grep -q "system/com.testhost.cloudflare-tunnel" "${MAIL_LOG}"
  grep -q "~opuser/.local/state/cloudflared/cloudflared-error.log" "${MAIL_LOG}"
  [ "$(state_field '.transitions.tunnel_down.alerted' || true)" = "true" ]
}

@test "no listener: counts as a failure and alerts at the threshold" {
  set_refused
  run_cycle
  run_cycle
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "no answer from http://127.0.0.1:29999/ready (curl exit 7)" "${MAIL_LOG}"
}

@test "outage: one alert while it lasts, then one recovery email" {
  set_ready 503 '{"status":503,"readyConnections":0}'
  for _ in 1 2 3 4 5 6; do run_cycle; done
  [ "$(mail_count || true)" -eq 1 ]

  set_ready 200 '{"status":200,"readyConnections":4}'
  run_cycle
  [ "$(mail_count || true)" -eq 2 ]
  grep -q "Subject: RESOLVED: \[TESTHOST\] Cloudflare Tunnel for test.example is ready again" "${MAIL_LOG}"
  [ "$(state_field '.failures' || true)" = "0" ]
  [ "$(state_field '.transitions.tunnel_down // "none"' || true)" = "none" ]
  grep -q "OK again after 6 failed checks" <<<"$(watchdog_log || true)"
}

@test "blip: recovery below the threshold resets the count and sends nothing" {
  set_ready 503 '{"status":503,"readyConnections":0}'
  run_cycle
  run_cycle
  set_ready 200 '{"status":200,"readyConnections":4}'
  run_cycle
  set_ready 503 '{"status":503,"readyConnections":0}'
  run_cycle
  run_cycle
  [ "$(mail_count || true)" -eq 0 ]
  [ "$(state_field '.failures' || true)" = "2" ]
}

@test "outage: a reminder goes out after ALERT_REMINDER_SECONDS" {
  set_ready 503 '{"status":503,"readyConnections":0}'
  for _ in 1 2 3; do run_cycle; done
  [ "$(mail_count || true)" -eq 1 ]
  # Pretend the alert went out 13 hours ago.
  local old
  old=$(($(date +%s) - 46800))
  jq --argjson t "${old}" '.transitions.tunnel_down.last_sent = $t' \
    "${CONFIG_DIR}/state.json" >"${CONFIG_DIR}/s.tmp"
  mv "${CONFIG_DIR}/s.tmp" "${CONFIG_DIR}/state.json"
  run_cycle
  [ "$(mail_count || true)" -eq 2 ]
  grep -q "Subject: \[reminder\] \[TESTHOST\] Cloudflare Tunnel" "${MAIL_LOG}"
}

@test "not ready: --check prints DOWN, exits 1, no email, no state" {
  set_ready 503 '{"status":503,"readyConnections":0}'
  run run_check
  [ "${status}" -eq 1 ]
  [[ "${output}" == DOWN:* ]]
  [ "$(mail_count || true)" -eq 0 ]
  [ ! -e "${CONFIG_DIR}/state.json" ]
}

@test "no listener: --check exits 1" {
  set_refused
  run run_check
  [ "${status}" -eq 1 ]
  [[ "${output}" == "DOWN: no answer"* ]]
}

# ---------------------------------------------------------------------------
# Robustness
# ---------------------------------------------------------------------------

@test "a 200 with a body that is not JSON still counts as ready" {
  set_ready 200 'not json'
  run run_cycle
  [ "${status}" -eq 0 ]
  [ "$(state_field '.failures' || true)" = "0" ]
  grep -q "OK: tunnel ready, unknown connections" <<<"$(watchdog_log || true)"
}

@test "a corrupt state file does not stop the check" {
  mkdir -p "${CONFIG_DIR}"
  echo 'garbage' >"${CONFIG_DIR}/state.json"
  set_ready 503 '{"status":503,"readyConnections":0}'
  run run_cycle
  [ "${status}" -eq 0 ]
  [ "$(state_field '.failures' || true)" = "1" ]
}

@test "missing alert library: exits 1 and logs why" {
  rm "${HOME}/.local/lib/alert-lib.sh"
  run run_cycle
  [ "${status}" -eq 1 ]
  grep -q "ERROR: alert library not found" <<<"$(watchdog_log || true)"
}

@test "an unknown argument exits 64" {
  run /bin/bash "${WATCHDOG}" --bogus
  [ "${status}" -eq 64 ]
}

@test "the email goes out under launchd's PATH (msmtp by absolute path)" {
  set_ready 503 '{"status":503,"readyConnections":0}'
  PATH=/usr/bin:/bin:/usr/sbin:/sbin run_cycle
  PATH=/usr/bin:/bin:/usr/sbin:/sbin run_cycle
  PATH=/usr/bin:/bin:/usr/sbin:/sbin run_cycle
  [ "$(mail_count || true)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

@test "rendered watchdog has no placeholders left" {
  run grep -n '__[A-Z_]*__' "${WATCHDOG}"
  [ "${status}" -eq 1 ]
}

@test "setup script substitutes every placeholder the templates use" {
  local tpl ph phs
  for tpl in tunnel-watchdog.sh com.tunnel-watchdog.plist; do
    phs=$(grep -o '__[A-Z_]*__' "${REPO_DIR}/app-setup/templates/${tpl}")
    [ -n "${phs}" ]
    while IFS= read -r ph; do
      grep -qF -- "-e \"s|${ph}|" "${SETUP_SCRIPT}" || {
        echo "setup script does not substitute ${ph} (${tpl})"
        return 1
      }
    done <<<"${phs}"
  done
}

@test "watchdog and cloudflared-setup.sh default to the same metrics port" {
  local a b
  a=$(grep -o 'TUNNEL_METRICS_PORT:-[0-9]*' "${REPO_DIR}/app-setup/cloudflared-setup.sh")
  b=$(grep -o 'TUNNEL_METRICS_PORT:-[0-9]*' "${SETUP_SCRIPT}")
  [ -n "${a}" ]
  [ "${a}" = "${b}" ]
}

@test "the plist is valid and runs the watchdog with /bin/bash every 60 s" {
  local plist="${TEST_TMPDIR}/w.plist"
  sed -e 's|__HOSTNAME_LOWER__|testhost|g' -e 's|__OPERATOR_USERNAME__|opuser|g' \
    "${REPO_DIR}/app-setup/templates/com.tunnel-watchdog.plist" >"${plist}"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "${plist}"
  fi
  grep -q '<string>/bin/bash</string>' "${plist}"
  grep -q '<string>/Users/opuser/.local/bin/tunnel-watchdog</string>' "${plist}"
  local interval
  interval=$(grep -A1 StartInterval "${plist}")
  [[ "${interval}" == *'<integer>60</integer>'* ]]
}
