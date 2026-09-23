#!/usr/bin/env bats
#
# Tests for plex-watchdog parsing, comparison, and state management.
# Run with: bats tests/plex-watchdog.bats
#
# These tests use sample XML fixtures and golden configs to exercise
# core logic without requiring a live Plex server or msmtp.

# BATS_TEST_FILENAME is provided by the BATS runtime
BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
FIXTURES_DIR="${REPO_DIR}/tests/fixtures"
WATCHDOG_TEMPLATE="${REPO_DIR}/app-setup/templates/plex-watchdog.sh"
CTL_TEMPLATE="${REPO_DIR}/app-setup/templates/plex-watchdog-ctl.sh"

setup() {
  # Create temp directory for each test
  TEST_TMPDIR=$(mktemp -d)

  # Sandbox HOME: the watchdog derives its token, state, log, msmtp config
  # and alert-lib paths from it.
  export HOME="${TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.config/msmtp" "${HOME}/.local/state" "${HOME}/.local/lib"
  touch "${HOME}/.config/msmtp/config"
  cp "${REPO_DIR}/app-setup/templates/alert-lib.sh" "${HOME}/.local/lib/alert-lib.sh"

  # The watchdog sets PATH to <HOMEBREW_PREFIX>/bin:/usr/bin:... itself, so
  # mocks go in a fake prefix that the rendered template points at.
  FAKE_BREW="${TEST_TMPDIR}/brew"
  mkdir -p "${FAKE_BREW}/bin"
  export MAIL_LOG="${TEST_TMPDIR}/mail.log"
  : >"${MAIL_LOG}"

  export CONFIG_DIR="${TEST_TMPDIR}/config"
  export GOLDEN_CONF="${CONFIG_DIR}/golden.conf"
  export STATE_FILE="${CONFIG_DIR}/state.json"
  export PLEX_TOKEN_FILE="${CONFIG_DIR}/token"
  export LOG_FILE="${TEST_TMPDIR}/watchdog.log"
  mkdir -p "${CONFIG_DIR}"
  touch "${LOG_FILE}"

  # Write a dummy token file
  echo "test-token-123" >"${PLEX_TOKEN_FILE}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Helper: extract and source specific functions from a script template.
# Replaces template placeholders so the script can be sourced.
# ---------------------------------------------------------------------------

source_watchdog_functions() {
  local tmp="${TEST_TMPDIR}/watchdog-functions.sh"
  # Replace placeholders, remove the main "$@" call at the bottom, and
  # stub out send_email so sourcing only defines functions.
  # Also override CONFIG_DIR to use the test's temp directory (the template
  # sets CONFIG_DIR=$HOME/.config/... which doesn't exist in CI).
  sed \
    -e 's/__HOSTNAME__/TESTHOST/g' \
    -e 's/__MONITORING_EMAIL__/test@example.com/g' \
    -e 's/^main "\$@"/# main "$@" — disabled for testing/' \
    -e "s|^CONFIG_DIR=.*|CONFIG_DIR=\"${CONFIG_DIR}\"|" \
    -e "s|HOMEBREW_PREFIX=\"[^\"]*\"|HOMEBREW_PREFIX=\"${FAKE_BREW}\"|" \
    "${WATCHDOG_TEMPLATE}" >"${tmp}"
  # Stub send_email
  echo 'send_email() { echo "MOCK_EMAIL: $1"; return 0; }' >>"${tmp}"
  # shellcheck source=/dev/null
  source "${tmp}"
}

source_ctl_functions() {
  local tmp="${TEST_TMPDIR}/ctl-functions.sh"
  # Replace placeholders, override CONFIG_DIR for CI, remove the case dispatch
  # at the bottom so sourcing only defines functions without executing a command.
  sed \
    -e 's/__HOSTNAME__/TESTHOST/g' \
    -e 's/__MONITORING_EMAIL__/test@example.com/g' \
    -e "s|^CONFIG_DIR=.*|CONFIG_DIR=\"${CONFIG_DIR}\"|" \
    "${CTL_TEMPLATE}" | sed '/^case "\${1:-}"/,$ d' >"${tmp}"
  # shellcheck source=/dev/null
  source "${tmp}"
}

# ===========================================================================
# Golden config parsing
# ===========================================================================

@test "load_golden: extracts uncommented key-value pairs" {
  source_watchdog_functions
  cp "${FIXTURES_DIR}/golden-basic.conf" "${GOLDEN_CONF}"

  run load_golden
  [ "$status" -eq 0 ]
  [[ "$output" == *"TranscoderCanOnlyRemuxVideo=0"* ]]
}

@test "load_golden: skips commented-out settings" {
  source_watchdog_functions
  cp "${FIXTURES_DIR}/golden-basic.conf" "${GOLDEN_CONF}"

  run load_golden
  [ "$status" -eq 0 ]
  # HardwareAcceleratedCodecs is commented out — should not appear
  [[ "$output" != *"HardwareAcceleratedCodecs"* ]]
  [[ "$output" != *"WanPerStreamMaxUploadRate"* ]]
}

@test "load_golden: handles multiple uncommented settings" {
  source_watchdog_functions
  cp "${FIXTURES_DIR}/golden-multi.conf" "${GOLDEN_CONF}"

  run load_golden
  [ "$status" -eq 0 ]
  [[ "$output" == *"TranscoderCanOnlyRemuxVideo=0"* ]]
  [[ "$output" == *"HardwareAcceleratedCodecs=1"* ]]
  [[ "$output" == *"TranscoderQuality=0"* ]]
  [[ "$output" == *"WanPerStreamMaxUploadRate=0"* ]]
}

@test "load_golden: fails when file is missing" {
  source_watchdog_functions
  rm -f "${GOLDEN_CONF}"

  run load_golden
  [ "$status" -ne 0 ]
}

@test "load_golden: fails when all settings are commented out" {
  source_watchdog_functions
  cat >"${GOLDEN_CONF}" <<'EOF'
# Everything is commented
# TranscoderCanOnlyRemuxVideo: 0
# HardwareAcceleratedCodecs: 1
EOF

  run load_golden
  [ "$status" -ne 0 ]
}

@test "load_golden: handles empty lines and whitespace" {
  source_watchdog_functions
  cat >"${GOLDEN_CONF}" <<'EOF'

  # Comment with leading whitespace
TranscoderCanOnlyRemuxVideo: 0


HardwareAcceleratedCodecs: 1

EOF

  run load_golden
  [ "$status" -eq 0 ]
  [[ "$output" == *"TranscoderCanOnlyRemuxVideo=0"* ]]
  [[ "$output" == *"HardwareAcceleratedCodecs=1"* ]]
}

# ===========================================================================
# XML parsing with xmllint
# ===========================================================================

@test "parse_prefs_xml: extracts id and value from Plex XML" {
  source_watchdog_functions
  local xml
  xml=$(cat "${FIXTURES_DIR}/plex-prefs-sample.xml")

  run parse_prefs_xml "${xml}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TranscoderCanOnlyRemuxVideo=1"* ]]
  [[ "$output" == *"HardwareAcceleratedCodecs=1"* ]]
  [[ "$output" == *"FriendlyName=TILSIT"* ]]
  [[ "$output" == *"TranscoderQuality=0"* ]]
}

@test "parse_prefs_xml: handles XML entities correctly" {
  source_watchdog_functions
  local xml
  xml=$(cat "${FIXTURES_DIR}/plex-prefs-sample.xml")

  run parse_prefs_xml "${xml}"
  [ "$status" -eq 0 ]
  # xmllint should decode &amp; to & and &quot; to "
  [[ "$output" == *'ValueWithSpecialChars=foo&bar=baz"test'* ]]
}

@test "parse_prefs_xml: output is sorted" {
  source_watchdog_functions
  local xml
  xml=$(cat "${FIXTURES_DIR}/plex-prefs-sample.xml")

  run parse_prefs_xml "${xml}"
  [ "$status" -eq 0 ]

  # Verify output is sorted by checking first and last entries
  local first_line last_line
  first_line=$(echo "$output" | head -1)
  last_line=$(echo "$output" | tail -1)
  [[ "$first_line" == "allowMediaDeletion="* ]]
  [[ "$last_line" == "WanPerStreamMaxUploadRate="* ]]
}

@test "parse_prefs_xml: extracts correct count of settings" {
  source_watchdog_functions
  local xml
  xml=$(cat "${FIXTURES_DIR}/plex-prefs-sample.xml")

  run parse_prefs_xml "${xml}"
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | wc -l | tr -d ' ')
  [ "$count" -eq 8 ]
}

# ===========================================================================
# State management
# ===========================================================================

@test "alert_state_read: returns empty JSON when state file does not exist" {
  source_watchdog_functions
  rm -f "${STATE_FILE}"

  run alert_state_read
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "alert_state_read: returns file contents when state file exists" {
  source_watchdog_functions
  echo '{"consecutive_failures": 3}' >"${STATE_FILE}"

  run alert_state_read
  [ "$status" -eq 0 ]
  [[ "$output" == *'"consecutive_failures": 3'* ]]
}

@test "alert_state_write: creates state file atomically" {
  source_watchdog_functions
  local state='{"test": true}'

  alert_state_write "${state}"

  [ -f "${STATE_FILE}" ]
  run cat "${STATE_FILE}"
  [[ "$output" == *'"test": true'* ]]

  # Verify no temp files left behind
  local tmp_count
  tmp_count=$(find "${CONFIG_DIR}" -name 'state.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$tmp_count" -eq 0 ]
}

@test "alert_state_get: extracts value from state JSON" {
  source_watchdog_functions
  echo '{"consecutive_failures": 5, "response_hash": "abc123"}' >"${STATE_FILE}"

  run alert_state_get "consecutive_failures" "0"
  [ "$output" = "5" ]

  run alert_state_get "response_hash" ""
  [ "$output" = "abc123" ]
}

@test "alert_state_get: returns default for missing keys" {
  source_watchdog_functions
  echo '{}' >"${STATE_FILE}"

  run alert_state_get "consecutive_failures" "0"
  [ "$output" = "0" ]

  run alert_state_get "missing_key" "default_val"
  [ "$output" = "default_val" ]
}

# ===========================================================================
# Drift detection (comparison logic)
# ===========================================================================

@test "drift detection: identifies setting that changed from golden" {
  source_watchdog_functions
  cp "${FIXTURES_DIR}/golden-basic.conf" "${GOLDEN_CONF}"
  echo '{}' >"${STATE_FILE}"

  local golden_prefs
  golden_prefs=$(load_golden)

  # Sample current prefs where TranscoderCanOnlyRemuxVideo=1 (golden says 0)
  local current_prefs="HardwareAcceleratedCodecs=1
TranscoderCanOnlyRemuxVideo=1
WanPerStreamMaxUploadRate=0"

  local drift_found=false
  while IFS='=' read -r golden_key golden_value; do
    [[ -z "${golden_key}" ]] && continue
    local current_value
    current_value=$(echo "${current_prefs}" | grep "^${golden_key}=" | head -1 | sed "s/^${golden_key}=//") || true
    if [[ "${current_value}" != "${golden_value}" ]]; then
      drift_found=true
    fi
  done <<<"${golden_prefs}"

  [ "${drift_found}" = "true" ]
}

@test "drift detection: no drift when values match golden" {
  source_watchdog_functions
  cp "${FIXTURES_DIR}/golden-basic.conf" "${GOLDEN_CONF}"

  local golden_prefs
  golden_prefs=$(load_golden)

  # Current prefs match golden (TranscoderCanOnlyRemuxVideo=0)
  local current_prefs="TranscoderCanOnlyRemuxVideo=0"

  local drift_found=false
  while IFS='=' read -r golden_key golden_value; do
    [[ -z "${golden_key}" ]] && continue
    local current_value
    current_value=$(echo "${current_prefs}" | grep "^${golden_key}=" | head -1 | sed "s/^${golden_key}=//") || true
    if [[ "${current_value}" != "${golden_value}" ]]; then
      drift_found=true
    fi
  done <<<"${golden_prefs}"

  [ "${drift_found}" = "false" ]
}

@test "drift detection: detects multiple drifted settings" {
  source_watchdog_functions
  cp "${FIXTURES_DIR}/golden-multi.conf" "${GOLDEN_CONF}"

  local golden_prefs
  golden_prefs=$(load_golden)

  # Two settings drifted
  local current_prefs="TranscoderCanOnlyRemuxVideo=1
HardwareAcceleratedCodecs=0
TranscoderQuality=0
WanPerStreamMaxUploadRate=0"

  local drift_count=0
  while IFS='=' read -r golden_key golden_value; do
    [[ -z "${golden_key}" ]] && continue
    local current_value
    current_value=$(echo "${current_prefs}" | grep "^${golden_key}=" | head -1 | sed "s/^${golden_key}=//") || true
    if [[ "${current_value}" != "${golden_value}" ]]; then
      ((drift_count += 1))
    fi
  done <<<"${golden_prefs}"

  [ "${drift_count}" -eq 2 ]
}

# ===========================================================================
# Hash-based fast path
# ===========================================================================

@test "hash check: identical XML produces identical hash" {
  local xml
  xml=$(cat "${FIXTURES_DIR}/plex-prefs-sample.xml")

  local hash1 hash2
  hash1=$(printf '%s' "${xml}" | shasum -a 256 | cut -d' ' -f1)
  hash2=$(printf '%s' "${xml}" | shasum -a 256 | cut -d' ' -f1)

  [ "${hash1}" = "${hash2}" ]
}

@test "hash check: different XML produces different hash" {
  local xml1 xml2
  xml1=$(cat "${FIXTURES_DIR}/plex-prefs-sample.xml")
  xml2=$(echo "${xml1}" | sed 's/value="1"/value="0"/')

  local hash1 hash2
  hash1=$(printf '%s' "${xml1}" | shasum -a 256 | cut -d' ' -f1)
  hash2=$(printf '%s' "${xml2}" | shasum -a 256 | cut -d' ' -f1)

  [ "${hash1}" != "${hash2}" ]
}

# ===========================================================================
# Accept command: golden.conf mutation
# ===========================================================================

@test "accept: updates golden value for drifted setting" {
  source_ctl_functions
  cp "${FIXTURES_DIR}/golden-basic.conf" "${GOLDEN_CONF}"
  echo '{}' >"${STATE_FILE}"

  # Simulate: golden says 0, we want to accept value 1
  local golden_content
  golden_content=$(cat "${GOLDEN_CONF}")
  golden_content=$(echo "${golden_content}" | sed "s|^TranscoderCanOnlyRemuxVideo:.*|TranscoderCanOnlyRemuxVideo: 1|")
  atomic_write "${GOLDEN_CONF}" "${golden_content}"

  # Verify the value changed
  run grep "^TranscoderCanOnlyRemuxVideo:" "${GOLDEN_CONF}"
  [[ "$output" == "TranscoderCanOnlyRemuxVideo: 1" ]]
}

@test "accept: preserves comments and structure" {
  source_ctl_functions
  cp "${FIXTURES_DIR}/golden-basic.conf" "${GOLDEN_CONF}"
  echo '{}' >"${STATE_FILE}"

  local golden_content
  golden_content=$(cat "${GOLDEN_CONF}")
  golden_content=$(echo "${golden_content}" | sed "s|^TranscoderCanOnlyRemuxVideo:.*|TranscoderCanOnlyRemuxVideo: 1|")
  atomic_write "${GOLDEN_CONF}" "${golden_content}"

  # Comments should still be there
  run grep "# === Transcoder ===" "${GOLDEN_CONF}"
  [ "$status" -eq 0 ]

  run grep "# === Network ===" "${GOLDEN_CONF}"
  [ "$status" -eq 0 ]

  run grep "# Disable video transcoding" "${GOLDEN_CONF}"
  [ "$status" -eq 0 ]

  # Commented-out settings should be unchanged
  run grep "# HardwareAcceleratedCodecs: 1" "${GOLDEN_CONF}"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Atomic write safety
# ===========================================================================

@test "atomic_write: file is complete (no partial writes)" {
  source_ctl_functions

  local long_content=""
  for i in $(seq 1 100); do
    long_content+="line ${i}: some test data here"$'\n'
  done

  atomic_write "${GOLDEN_CONF}" "${long_content}"

  local line_count
  line_count=$(wc -l <"${GOLDEN_CONF}" | tr -d ' ')
  # 100 lines + trailing newline from printf
  [ "$line_count" -ge 100 ]
}

@test "atomic_write: no temp files left on success" {
  source_ctl_functions
  atomic_write "${STATE_FILE}" '{"test": true}'

  local leftover
  leftover=$(find "${CONFIG_DIR}" -name 'state.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$leftover" -eq 0 ]
}

# ===========================================================================
# Plex token file
# ===========================================================================

@test "get_plex_token: reads token from file" {
  # Write token to the location the script expects (HOME-based path)
  local script_token_dir="${HOME}/.config/plex-watchdog"
  mkdir -p "${script_token_dir}"
  echo "test-token-123" >"${script_token_dir}/token"

  source_watchdog_functions

  run get_plex_token
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-token-123"* ]]

  # Clean up
  rm -f "${script_token_dir}/token"
}

@test "get_plex_token: fails when token file missing" {
  source_watchdog_functions
  PLEX_TOKEN_FILE="${CONFIG_DIR}/token"
  rm -f "${PLEX_TOKEN_FILE}"

  run get_plex_token
  [ "$status" -ne 0 ]
}

@test "get_plex_token: strips whitespace from token" {
  source_watchdog_functions
  PLEX_TOKEN_FILE="${CONFIG_DIR}/token"
  printf '  test-token-with-spaces  \n' >"${PLEX_TOKEN_FILE}"

  run get_plex_token
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-token-with-spaces"* ]]
}

# ===========================================================================
# Heartbeat
#
# last_heartbeat is written in UTC with a trailing Z. It must be parsed as
# UTC too: parsed as local time, a zone west of UTC pushes it into the
# future and the hourly heartbeat stops for hours at a time.
# ===========================================================================

@test "maybe_heartbeat: logs when the last heartbeat is 2 hours old, west of UTC" {
  export TZ=America/Los_Angeles
  source_watchdog_functions
  : >"${LOG_FILE}"
  cp "${FIXTURES_DIR}/golden-basic.conf" "${GOLDEN_CONF}"
  local two_hours_ago
  two_hours_ago=$(date -u -r "$(($(date +%s) - 7200))" '+%Y-%m-%dT%H:%M:%SZ')
  echo "{\"last_heartbeat\": \"${two_hours_ago}\"}" >"${STATE_FILE}"

  maybe_heartbeat

  grep -q "OK: .* settings monitored, no drift" "${LOG_FILE}"
  [ "$(alert_state_get last_heartbeat "")" != "${two_hours_ago}" ]
}

@test "maybe_heartbeat: stays quiet when the last heartbeat is 30 minutes old" {
  export TZ=America/Los_Angeles
  source_watchdog_functions
  : >"${LOG_FILE}"
  cp "${FIXTURES_DIR}/golden-basic.conf" "${GOLDEN_CONF}"
  local half_hour_ago
  half_hour_ago=$(date -u -r "$(($(date +%s) - 1800))" '+%Y-%m-%dT%H:%M:%SZ')
  echo "{\"last_heartbeat\": \"${half_hour_ago}\"}" >"${STATE_FILE}"

  maybe_heartbeat

  [ "$(grep -c "settings monitored" "${LOG_FILE}")" -eq 0 ]
  [ "$(alert_state_get last_heartbeat "")" = "${half_hour_ago}" ]
}

# ===========================================================================
# Full poll cycles: email under launchd, and the shared alert library
#
# launchd runs this agent as `/bin/bash <script>` (bash 3.2) with
# PATH=/usr/bin:/bin:/usr/sbin:/sbin. msmtp is a Homebrew binary, so the old
# bare `msmtp ... 2>/dev/null` failed on every launchd run and nobody saw it.
# ===========================================================================

# Render the whole template as plex-watchdog-setup.sh does, with the Homebrew
# prefix pointed at the fake one. Uses the real $HOME-based paths.
render_watchdog() {
  WATCHDOG="${TEST_TMPDIR}/plex-watchdog"
  sed \
    -e 's/__HOSTNAME__/TESTHOST/g' \
    -e 's/__MONITORING_EMAIL__/test@example.com/g' \
    -e "s|HOMEBREW_PREFIX=\"[^\"]*\"|HOMEBREW_PREFIX=\"${FAKE_BREW}\"|" \
    "${WATCHDOG_TEMPLATE}" >"${WATCHDOG}"

  mkdir -p "${HOME}/.config/plex-watchdog"
  echo "test-token-123" >"${HOME}/.config/plex-watchdog/token"
  cp "${FIXTURES_DIR}/golden-basic.conf" "${HOME}/.config/plex-watchdog/golden.conf"
}

# curl mock: serves the sample prefs (TranscoderCanOnlyRemuxVideo=1, golden
# says 0, so one setting has drifted), or fails when PLEX_DOWN=1.
write_curl_mock() {
  cat >"$1" <<MOCK
#!/usr/bin/env bash
if [[ "\${PLEX_DOWN:-0}" == "1" ]]; then
  exit 7
fi
cat "${FIXTURES_DIR}/plex-prefs-sample.xml"
MOCK
  chmod +x "$1"
}

write_msmtp_mock() {
  cat >"${FAKE_BREW}/bin/msmtp" <<'MOCK'
#!/usr/bin/env bash
{ echo "=== MAIL ==="; cat; } >>"${MAIL_LOG}"
MOCK
  chmod +x "${FAKE_BREW}/bin/msmtp"
}

mail_count() {
  grep -c '^=== MAIL ===' "${MAIL_LOG}" || true
}

watchdog_log() {
  cat "${HOME}/.local/state/plex-watchdog.log" 2>/dev/null || true
}

# Run one cycle the way launchd does: /bin/bash, launchd's PATH, a bare env.
# Why the extra dir: curl must be mocked for BOTH the old and the new code, or
# the old code would query the live Plex on this host. The new watchdog
# replaces PATH with <prefix>/bin:/usr/bin:..., so it finds curl in the fake
# prefix; the old one never changes PATH, so it finds this copy. msmtp exists
# only in the fake prefix, so the only way to send is to look it up there by
# absolute path — which is the bug under test.
run_launchd_cycle() {
  local launchd_extra="${TEST_TMPDIR}/launchd-extra/bin"
  mkdir -p "${launchd_extra}"
  write_curl_mock "${launchd_extra}/curl"

  env -i \
    PATH="${launchd_extra}:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="${HOME}" \
    MAIL_LOG="${MAIL_LOG}" \
    PLEX_DOWN="${PLEX_DOWN:-0}" \
    /bin/bash "${WATCHDOG}"
}

@test "launchd PATH: the drift alert email is sent when Homebrew is not on PATH" {
  render_watchdog
  write_curl_mock "${FAKE_BREW}/bin/curl"
  write_msmtp_mock

  run run_launchd_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] Plex setting drift detected" "${MAIL_LOG}"
  grep -q "Drift alert email sent" <<<"$(watchdog_log)"
}

@test "launchd PATH: the Plex-unreachable email is built under /bin/bash 3.2" {
  # It used ${HOSTNAME_LABEL,,}, which is a "bad substitution" in bash 3.2.
  render_watchdog
  write_curl_mock "${FAKE_BREW}/bin/curl"
  write_msmtp_mock
  echo '{"consecutive_failures": 2}' >"${HOME}/.config/plex-watchdog/state.json"

  PLEX_DOWN=1 run run_launchd_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] Plex server unreachable" "${MAIL_LOG}"
  grep -q "ssh operator@testhost" "${MAIL_LOG}"
}

@test "a failed drift email is logged with msmtp's stderr" {
  render_watchdog
  write_curl_mock "${FAKE_BREW}/bin/curl"
  cat >"${FAKE_BREW}/bin/msmtp" <<'MOCK'
#!/usr/bin/env bash
echo "msmtp: cannot connect to smtp.gmail.com" >&2
exit 69
MOCK
  chmod +x "${FAKE_BREW}/bin/msmtp"

  run bash "${WATCHDOG}"
  [ "$status" -eq 0 ]
  grep -q "cannot connect to smtp.gmail.com" <<<"$(watchdog_log)"
  grep -q "ERROR: Failed to send drift alert email" <<<"$(watchdog_log)"
}

@test "a missing alert library stops the watchdog with an ERROR in its log" {
  render_watchdog
  rm -f "${HOME}/.local/lib/alert-lib.sh"

  run bash "${WATCHDOG}"
  [ "$status" -eq 1 ]
  grep -q "ERROR: alert library not found at ${HOME}/.local/lib/alert-lib.sh" <<<"$(watchdog_log)"
}

@test "plex-watchdog-setup.sh deploys the alert library" {
  grep -q 'ALERT_LIB_DEST="${OPERATOR_HOME}/.local/lib/alert-lib.sh"' \
    "${REPO_DIR}/app-setup/plex-watchdog-setup.sh"
  grep -q 'sudo cp "${ALERT_LIB_TEMPLATE}" "${ALERT_LIB_DEST}"' \
    "${REPO_DIR}/app-setup/plex-watchdog-setup.sh"
}
