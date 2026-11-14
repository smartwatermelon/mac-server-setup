#!/usr/bin/env bats
#
# Tests for app-setup/templates/access-policy-watchdog.sh — the Cloudflare
# Access policy-drift watchdog for the tunnel (G2, issue #209).
#
# Through the tunnel there is no login in front of Transmission except the
# Access policy. cloudflared only checks that a token is valid for this
# application, so a widened policy (Everyone, a second email, an email
# domain, another IdP) lets every newly allowed visitor through. This
# watchdog is the only signal for that, so these tests pin:
#
#   1. The expected rule passes, and every widening alerts.
#   2. A 404 (application or policy deleted) alerts at once.
#   3. An unreadable API alerts only after a streak, and never sends a false
#      all-clear for an open drift alert.
#   4. Email works under launchd's PATH, and the token never reaches curl's
#      argument list.
#   5. The tunnel ingress is exactly one Access-protected hostname plus the
#      404 catch-all, with private-network (WARP) routing off.
#   6. With HOME_ASSISTANT_HOSTNAME set, exactly two: the main host, then
#      the HA host, both on the one Access application. Unset, today's rule.
#
# The watchdog runs end to end against a curl mock in a fake Homebrew prefix
# (the pattern from pia-port-watchdog.bats). Fixtures:
# tests/fixtures/cloudflare-access/.
#
# Run with: bats tests/access-policy-watchdog.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
# May be overridden to run these tests against a known-bad watchdog.
TEMPLATE="${TEMPLATE:-${REPO_DIR}/app-setup/templates/access-policy-watchdog.sh}"
FIXTURES="${REPO_DIR}/tests/fixtures/cloudflare-access"

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

  CONFIG_DIR="${HOME}/.config/access-policy-watchdog"
  mkdir -p "${CONFIG_DIR}"
  printf 'test-api-token-value\n' >"${CONFIG_DIR}/token"
  chmod 600 "${CONFIG_DIR}/token"

  export MAIL_LOG="${TEST_TMPDIR}/mail.log"
  : >"${MAIL_LOG}"

  set_app "app-ok.json" 200
  set_policy "policy-ok.json" 200
  set_tunnel "tunnel-ok.json" 200

  write_curl_mock
  write_msmtp_mock
  render_template
  # Also first on the test's own PATH, so even a watchdog that does not set
  # PATH gets the mock and can never reach the real Cloudflare API.
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

render_template() {
  WATCHDOG="${TEST_TMPDIR}/access-policy-watchdog.sh"
  sed \
    -e 's|__HOSTNAME__|TESTHOST|g' \
    -e 's|__MONITORING_EMAIL__|ops@example.com|g' \
    -e 's|__EXTERNAL_HOSTNAME__|test.example|g' \
    -e 's|__CLOUDFLARE_ACCOUNT_ID__|acct0123|g' \
    -e 's|__CLOUDFLARE_ACCESS_APP_ID__|app-0123|g' \
    -e 's|__CLOUDFLARE_ACCESS_POLICY_ID__|pol-0123|g' \
    -e 's|__CLOUDFLARE_ACCESS_IDP_ID__|idp-google|g' \
    -e 's|__ACCESS_ALLOWED_EMAIL__|allowed@example.com|g' \
    -e 's|__CLOUDFLARE_TUNNEL_ID__|tun-0123|g' \
    -e 's|__CLOUDFLARE_ACCESS_TEAM_NAME__|test-team|g' \
    -e 's|__CLOUDFLARE_ACCESS_AUD_TAG__|aud0123|g' \
    -e "s|__HOME_ASSISTANT_HOSTNAME__|${HA_HOST:-}|g" \
    -e "s|HOMEBREW_PREFIX=\"[^\"]*\"|HOMEBREW_PREFIX=\"${FAKE_BREW}\"|" \
    "${TEMPLATE}" >"${WATCHDOG}"
  chmod +x "${WATCHDOG}"
}

# The API answers are read from files, so a test can change them between
# cycles. set_app/set_policy FIXTURE HTTP_CODE; FIXTURE is a file name in
# FIXTURES or an absolute path.
set_app() {
  fixture_path "$1" >"${TEST_TMPDIR}/app_fixture"
  echo "$2" >"${TEST_TMPDIR}/app_code"
}
set_policy() {
  fixture_path "$1" >"${TEST_TMPDIR}/policy_fixture"
  echo "$2" >"${TEST_TMPDIR}/policy_code"
}
set_tunnel() {
  fixture_path "$1" >"${TEST_TMPDIR}/tunnel_fixture"
  echo "$2" >"${TEST_TMPDIR}/tunnel_code"
}
fixture_path() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "${FIXTURES}/$1" ;;
  esac
}

# A variant of a fixture, built with a jq filter. Prints its path.
fixture_variant() {
  local base="$1" filter="$2" out
  out="${TEST_TMPDIR}/variant-$RANDOM-$RANDOM.json"
  jq "${filter}" "${FIXTURES}/${base}" >"${out}"
  echo "${out}"
}

# curl mock: reads the -K config from stdin (and records it), writes the
# fixture to the -o file, prints the HTTP code for -w. A file named
# curl_fail makes every call fail like a network error.
write_curl_mock() {
  cat >"${MOCK_BIN_DIR}/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_TMPDIR}/curl_argv"
cat >>"${TEST_TMPDIR}/curl_stdin"
if [[ -e "${TEST_TMPDIR}/curl_fail" ]]; then
  exit 7
fi
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "${url}" in
  */accounts/acct0123/access/apps/app-0123) kind=app ;;
  */accounts/acct0123/access/policies/pol-0123) kind=policy ;;
  */accounts/acct0123/cfd_tunnel/tun-0123/configurations) kind=tunnel ;;
  *) echo "unexpected URL ${url}" >&2; exit 22 ;;
esac
cp "$(cat "${TEST_TMPDIR}/${kind}_fixture")" "${out}"
printf '%s' "$(cat "${TEST_TMPDIR}/${kind}_code")"
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

# /bin/bash, as the LaunchAgent runs it: on macOS that is bash 3.2, so every
# test also checks 3.2 compatibility.
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
  cat "${HOME}/.local/state/access-policy-watchdog.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The expected rule
# ---------------------------------------------------------------------------

@test "expected rule: passes, no email, no open alert" {
  run run_cycle
  [ "${status}" -eq 0 ]
  [ "$(mail_count || true)" -eq 0 ]
  [ "$(state_field '.transitions.policy_drift // "none"' || true)" = "none" ]
  grep -q "OK: test.example Access application, policy and tunnel ingress match" <<<"$(watchdog_log || true)"
}

@test "expected rule: --check prints OK and exits 0" {
  run run_check
  [ "${status}" -eq 0 ]
  [[ "${output}" == OK:* ]]
}

@test "expected rule: the email comparison ignores case" {
  set_policy "$(fixture_variant policy-ok.json '.result.include[0].email.email = "Allowed@Example.COM"' || true)" 200
  run run_check
  [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Widened or changed rules: every one must alert
# ---------------------------------------------------------------------------

assert_drift_alert() {
  local out rc=0
  out=$(run_check) || rc=$?
  [ "${rc}" -eq 1 ]
  [[ "${out}" == DRIFT:* ]]
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] Cloudflare Access or tunnel config for test.example changed" "${MAIL_LOG}"
  [ "$(state_field '.transitions.policy_drift.alerted' || true)" = "true" ]
}

@test "drift: an 'everyone' include alerts" {
  set_policy policy-everyone.json 200
  assert_drift_alert
  grep -qF '"everyone"' "${MAIL_LOG}"
}

@test "drift: a second email alerts" {
  set_policy policy-second-email.json 200
  assert_drift_alert
  grep -qF 'someone-else@example.com' "${MAIL_LOG}"
}

@test "drift: an email_domain include alerts" {
  set_policy policy-email-domain.json 200
  assert_drift_alert
  grep -qF 'email_domain' "${MAIL_LOG}"
}

@test "drift: a different single email alerts" {
  set_policy "$(fixture_variant policy-ok.json '.result.include[0].email.email = "intruder@example.com"' || true)" 200
  assert_drift_alert
}

@test "drift: a selector not on any list (login_method) alerts" {
  set_policy "$(fixture_variant policy-ok.json '.result.include += [{"login_method": {"id": "otp"}}]' || true)" 200
  assert_drift_alert
}

@test "drift: an extra IdP on the application alerts" {
  set_app app-extra-idp.json 200
  assert_drift_alert
  grep -qF 'idp-onetimepin' "${MAIL_LOG}"
}

@test "drift: an empty IdP list (every IdP allowed) alerts" {
  set_app "$(fixture_variant app-ok.json '.result.allowed_idps = []' || true)" 200
  assert_drift_alert
}

@test "drift: a second policy attached to the application alerts" {
  set_app "$(fixture_variant app-ok.json '.result.policies += [{"id": "pol-bypass", "decision": "bypass", "include": [{"everyone": {}}]}]' || true)" 200
  assert_drift_alert
  grep -qF 'pol-bypass' "${MAIL_LOG}"
}

@test "drift: our policy detached from the application alerts" {
  set_app "$(fixture_variant app-ok.json '.result.policies = []' || true)" 200
  assert_drift_alert
}

@test "drift: a decision other than allow alerts" {
  set_policy "$(fixture_variant policy-ok.json '.result.decision = "bypass"' || true)" 200
  assert_drift_alert
}

@test "drift: a require or exclude rule alerts" {
  set_policy "$(fixture_variant policy-ok.json '.result.require = [{"everyone": {}}]' || true)" 200
  assert_drift_alert
}

@test "drift: a different application domain alerts" {
  set_app "$(fixture_variant app-ok.json '.result.domain = "other.example"' || true)" 200
  assert_drift_alert
}

@test "drift: one email per drift, then a recovery email when fixed" {
  set_policy policy-everyone.json 200
  run_cycle
  run_cycle
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]

  set_policy policy-ok.json 200
  run_cycle
  [ "$(mail_count || true)" -eq 2 ]
  grep -q "Subject: RESOLVED: \[TESTHOST\] Cloudflare Access or tunnel config for test.example matches again" "${MAIL_LOG}"
  [ "$(state_field '.transitions.policy_drift // "none"' || true)" = "none" ]
  [ "$(state_field '.drift_fingerprint // "none"' || true)" = "none" ]
}

@test "drift: a further change while alerted sends one more email" {
  set_policy policy-second-email.json 200
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]

  set_policy policy-everyone.json 200
  run_cycle
  [ "$(mail_count || true)" -eq 2 ]
  grep -q "Subject: \[TESTHOST\] Cloudflare Access or tunnel config for test.example changed again" "${MAIL_LOG}"

  run_cycle
  [ "$(mail_count || true)" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Tunnel ingress: exactly one Access-protected rule plus the 404 catch-all
# ---------------------------------------------------------------------------

@test "tunnel: the hostname comparison ignores case" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.ingress[0].hostname = "Test.Example"' || true)" 200
  run run_check
  [ "${status}" -eq 0 ]
}

@test "tunnel: no warp-routing key at all passes (off is the default)" {
  set_tunnel "$(fixture_variant tunnel-ok.json 'del(.result.config["warp-routing"])' || true)" 200
  run run_check
  [ "${status}" -eq 0 ]
}

@test "tunnel drift: access.required turned off alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.ingress[0].originRequest.access.required = false' || true)" 200
  assert_drift_alert
  grep -qF 'Tunnel ingress' "${MAIL_LOG}"
}

@test "tunnel drift: the access block removed alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json 'del(.result.config.ingress[0].originRequest)' || true)" 200
  assert_drift_alert
}

@test "tunnel drift: a different AUD tag alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.ingress[0].originRequest.access.audTag = ["aud-other"]' || true)" 200
  assert_drift_alert
}

@test "tunnel drift: a different team name alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.ingress[0].originRequest.access.teamName = "other-team"' || true)" 200
  assert_drift_alert
}

@test "tunnel drift: a second public hostname alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.ingress |= [{"hostname": "open.test.example", "service": "http://127.0.0.1:8080"}] + .' || true)" 200
  assert_drift_alert
  grep -qF 'open.test.example' "${MAIL_LOG}"
}

@test "tunnel drift: a path rule under our hostname alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.ingress |= [{"hostname": "test.example", "path": "/transmission", "service": "http://127.0.0.1:9091"}] + .' || true)" 200
  assert_drift_alert
}

@test "tunnel drift: a different origin service alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.ingress[0].service = "http://127.0.0.1:9091"' || true)" 200
  assert_drift_alert
}

@test "tunnel drift: a catch-all that serves something alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.ingress[1].service = "http://127.0.0.1:8080"' || true)" 200
  assert_drift_alert
}

@test "tunnel drift: private-network (WARP) routing turned on alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config["warp-routing"].enabled = true' || true)" 200
  assert_drift_alert
  grep -qF 'warp-routing' "${MAIL_LOG}"
}

@test "tunnel drift: an unexpected top-level config key alerts" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config.originRequest = {"noTLSVerify": true}' || true)" 200
  assert_drift_alert
  grep -qF 'originRequest' "${MAIL_LOG}"
}

@test "tunnel: a config the check cannot parse counts as an API failure" {
  set_tunnel "$(fixture_variant tunnel-ok.json '.result.config = "x"' || true)" 200
  run run_check
  [ "${status}" -eq 2 ]
  grep -q "^API ERROR: .*unexpected shape" <<<"${output}"
}

@test "tunnel: a 403 names the token permission the check needs" {
  set_tunnel api-error.json 403
  run run_check
  [ "${status}" -eq 2 ]
  grep -q "^API ERROR: .*tunnel.*HTTP 403.*Cloudflare Tunnel: Read" <<<"${output}"
}

@test "tunnel: the expected origin matches the Caddyfile tunnel site" {
  local port
  port=$(sed -n 's|^http://:\([0-9][0-9]*\) {$|\1|p' "${REPO_DIR}/app-setup/templates/Caddyfile")
  [ -n "${port}" ]
  grep -qF "TUNNEL_ORIGIN_SERVICE=\"http://127.0.0.1:${port}\"" "${TEMPLATE}"
}

@test "setup: every watchdog placeholder is substituted by the setup script" {
  local ph
  while IFS= read -r ph; do
    grep -qF "s|${ph}|" "${REPO_DIR}/app-setup/access-policy-watchdog-setup.sh" \
      || { echo "not substituted: ${ph}"; return 1; }
  done < <(grep -o '__[A-Z_]*__' "${TEMPLATE}" | sort -u || true)
}

# ---------------------------------------------------------------------------
# Optional Home Assistant host (HOME_ASSISTANT_HOSTNAME)
# ---------------------------------------------------------------------------

# Render the watchdog with the HA host set, and the matching API answers.
ha_on() {
  HA_HOST=ha.test.example render_template
  set_app app-ha.json 200
  set_tunnel tunnel-ha.json 200
}

@test "ha off: today's application response, with destinations, passes" {
  set_app app-destinations.json 200
  run run_check
  [ "${status}" -eq 0 ]
  [[ "${output}" == OK:* ]]
}

@test "ha off: an extra HA ingress rule alerts" {
  set_tunnel tunnel-ha.json 200
  assert_drift_alert
  grep -qF 'ha.test.example' "${MAIL_LOG}"
}

@test "ha off: an extra HA destination on the application alerts" {
  set_app app-ha.json 200
  assert_drift_alert
  grep -qF 'destinations' "${MAIL_LOG}"
}

@test "ha off: a non-public destination alerts" {
  set_app "$(fixture_variant app-destinations.json '.result.destinations[0].type = "private"' || true)" 200
  assert_drift_alert
}

@test "ha on: the matching application and ingress pass" {
  ha_on
  run run_check
  [ "${status}" -eq 0 ]
  [[ "${output}" == OK:* ]]
  run run_cycle
  [ "$(mail_count || true)" -eq 0 ]
}

@test "ha on: destinations compare without order or case" {
  ha_on
  set_app "$(fixture_variant app-ha.json '.result.destinations |= (reverse | .[0].uri = "HA.Test.Example") | .result.self_hosted_domains |= reverse' || true)" 200
  run run_check
  [ "${status}" -eq 0 ]
}

@test "ha on: an ingress without the HA rule alerts" {
  ha_on
  set_tunnel tunnel-ok.json 200
  assert_drift_alert
  grep -qF 'Tunnel ingress' "${MAIL_LOG}"
  grep -qF 'ha.test.example (both on this one application)' "${MAIL_LOG}"
}

@test "ha on: the HA rule without access.required alerts" {
  ha_on
  set_tunnel "$(fixture_variant tunnel-ha.json '.result.config.ingress[1].originRequest.access.required = false' || true)" 200
  assert_drift_alert
}

@test "ha on: the HA rule without the access block alerts" {
  ha_on
  set_tunnel "$(fixture_variant tunnel-ha.json 'del(.result.config.ingress[1].originRequest)' || true)" 200
  assert_drift_alert
}

@test "ha on: the HA rule to another service alerts" {
  ha_on
  set_tunnel "$(fixture_variant tunnel-ha.json '.result.config.ingress[1].service = "http://192.168.1.20:8123"' || true)" 200
  assert_drift_alert
}

@test "ha on: the HA rule ahead of the main rule alerts" {
  ha_on
  set_tunnel "$(fixture_variant tunnel-ha.json '.result.config.ingress |= [.[1], .[0], .[2]]' || true)" 200
  assert_drift_alert
}

@test "ha on: a third hostname alerts" {
  ha_on
  set_tunnel "$(fixture_variant tunnel-ha.json '.result.config.ingress |= .[0:2] + [(.[1] | .hostname = "x.test.example")] + .[2:]' || true)" 200
  assert_drift_alert
}

@test "ha on: an application without the HA destination alerts" {
  ha_on
  set_app app-destinations.json 200
  assert_drift_alert
  grep -qF 'destinations' "${MAIL_LOG}"
}

@test "ha on: an application response with no destinations alerts" {
  ha_on
  set_app app-ok.json 200
  assert_drift_alert
}

@test "ha on: self_hosted_domains without the HA host alerts" {
  ha_on
  set_app "$(fixture_variant app-ha.json '.result.self_hosted_domains = ["test.example"]' || true)" 200
  assert_drift_alert
  grep -qF 'self_hosted_domains' "${MAIL_LOG}"
}

@test "ha on: a third destination alerts" {
  ha_on
  set_app "$(fixture_variant app-ha.json '.result.destinations += [{"type": "public", "uri": "x.test.example"}]' || true)" 200
  assert_drift_alert
}

@test "ha on: the main domain still has to be the application domain" {
  ha_on
  set_app "$(fixture_variant app-ha.json '.result.domain = "ha.test.example"' || true)" 200
  assert_drift_alert
}

# ---------------------------------------------------------------------------
# Missing objects (HTTP 404): confirmed bad, alert at once
# ---------------------------------------------------------------------------

@test "missing: a deleted application alerts on the first poll" {
  set_app not-found.json 404
  run run_check
  [ "${status}" -eq 1 ]
  [[ "${output}" == MISSING:* ]]

  run run_cycle
  [ "${status}" -eq 0 ]
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] Cloudflare Access or tunnel object for test.example is missing" "${MAIL_LOG}"
  grep -q "the Access application app-0123" "${MAIL_LOG}"
  [ "$(state_field '.api_failures' || true)" = "0" ]
}

@test "missing: a deleted policy alerts on the first poll" {
  set_policy not-found.json 404
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "the Access policy pol-0123" "${MAIL_LOG}"
}

@test "missing: a deleted tunnel alerts on the first poll" {
  set_tunnel not-found.json 404
  run run_check
  [ "${status}" -eq 1 ]
  [[ "${output}" == MISSING:*"the tunnel tun-0123"* ]]
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "the tunnel tun-0123" "${MAIL_LOG}"
}

# ---------------------------------------------------------------------------
# API failures: unknown state
# ---------------------------------------------------------------------------

@test "api error: alerts only after 3 failed polls in a row" {
  set_app api-error.json 403
  run run_check
  [ "${status}" -eq 2 ]
  [[ "${output}" == "API ERROR:"*"HTTP 403"*"Authentication error"* ]]

  run_cycle
  run_cycle
  [ "$(mail_count || true)" -eq 0 ]
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] Access policy watchdog cannot read Cloudflare" "${MAIL_LOG}"
  [ "$(state_field '.api_failures' || true)" = "3" ]

  set_app app-ok.json 200
  run_cycle
  [ "$(mail_count || true)" -eq 2 ]
  grep -q "Subject: RESOLVED: \[TESTHOST\] Access policy watchdog reads Cloudflare again" "${MAIL_LOG}"
  [ "$(state_field '.api_failures' || true)" = "0" ]
}

@test "api error: a network failure streak alerts too" {
  touch "${TEST_TMPDIR}/curl_fail"
  run_cycle
  run_cycle
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "curl exit 7" "${MAIL_LOG}"
}

@test "api error: a 200 that is not a Cloudflare success counts as a failure" {
  set_policy "$(fixture_variant policy-ok.json '.success = false' || true)" 200
  run run_check
  [ "${status}" -eq 2 ]
}

@test "api error: a response the rule check cannot parse counts as a failure" {
  set_policy "$(fixture_variant policy-ok.json '.result.include = "x"' || true)" 200
  run run_check
  [ "${status}" -eq 2 ]
  # jq's own error also lands in ${output} (stderr); match the line we print.
  grep -q "^API ERROR: .*unexpected shape" <<<"${output}"

  run_cycle
  run_cycle
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] Access policy watchdog cannot read Cloudflare" "${MAIL_LOG}"
  grep -q "unexpected shape" <<<"$(watchdog_log || true)"
}

@test "api error: does not resolve an open drift alert" {
  set_policy policy-everyone.json 200
  run_cycle
  [ "$(mail_count || true)" -eq 1 ]

  touch "${TEST_TMPDIR}/curl_fail"
  run_cycle
  run_cycle
  # Two failures: below the threshold, so no email of any kind, and above
  # all no RESOLVED for the drift.
  [ "$(mail_count || true)" -eq 1 ]
  run grep -c "RESOLVED" "${MAIL_LOG}"
  [ "${output}" = "0" ]
  [ "$(state_field '.transitions.policy_drift.alerted' || true)" = "true" ]
}

@test "api error: a missing token file counts as an API failure" {
  rm -f "${CONFIG_DIR}/token"
  run run_cycle
  [ "${status}" -eq 2 ]
  run_cycle || true
  run_cycle || true
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "token" "${MAIL_LOG}"
}

# ---------------------------------------------------------------------------
# Token handling and launchd
# ---------------------------------------------------------------------------

@test "token: sent to curl on stdin, never in its argument list" {
  run_cycle
  grep -qF 'header = "Authorization: Bearer test-api-token-value"' "${TEST_TMPDIR}/curl_stdin"
  run grep -F 'test-api-token-value' "${TEST_TMPDIR}/curl_argv"
  [ "${status}" -ne 0 ]
}

@test "launchd PATH: the drift email is sent when Homebrew is not on PATH" {
  # msmtp exists only in the fake prefix, so alert-lib must find it by
  # absolute path. curl is mocked in an extra dir too, so a watchdog that
  # does not set PATH still gets the mock and never calls the real API.
  local launchd_extra="${TEST_TMPDIR}/launchd-extra/bin"
  mkdir -p "${launchd_extra}"
  cp "${MOCK_BIN_DIR}/curl" "${launchd_extra}/curl"
  set_policy policy-everyone.json 200
  run env -i \
    PATH="${launchd_extra}:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="${HOME}" \
    TEST_TMPDIR="${TEST_TMPDIR}" \
    MAIL_LOG="${MAIL_LOG}" \
    /bin/bash "${WATCHDOG}"
  [ "${status}" -eq 0 ]
  [ "$(mail_count || true)" -eq 1 ]
  grep -q "Cloudflare Access or tunnel config for test.example changed" "${MAIL_LOG}"
}

@test "a missing alert library stops the watchdog with an ERROR in its log" {
  rm -f "${HOME}/.local/lib/alert-lib.sh"
  run run_cycle
  [ "${status}" -eq 1 ]
  grep -q "ERROR: alert library not found" <<<"$(watchdog_log || true)"
}

@test "plist: renders to a valid LaunchAgent that runs every 15 minutes" {
  sed -e 's|__HOSTNAME_LOWER__|testhost|g' -e 's|__OPERATOR_USERNAME__|operator|g' \
    "${REPO_DIR}/app-setup/templates/com.access-policy-watchdog.plist" >"${TEST_TMPDIR}/agent.plist"
  plutil -lint "${TEST_TMPDIR}/agent.plist"
  [ "$(plutil -extract StartInterval raw "${TEST_TMPDIR}/agent.plist" || true)" = "900" ]
  [ "$(plutil -extract ProgramArguments.0 raw "${TEST_TMPDIR}/agent.plist" || true)" = "/bin/bash" ]
  [ "$(plutil -extract Label raw "${TEST_TMPDIR}/agent.plist" || true)" = "com.testhost.access-policy-watchdog" ]
}
