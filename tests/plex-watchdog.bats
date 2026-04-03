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
    "${WATCHDOG_TEMPLATE}" >"${tmp}"
  # Stub send_email
  echo 'send_email() { echo "MOCK_EMAIL: $1"; return 0; }' >>"${tmp}"
  # shellcheck source=/dev/null
  source "${tmp}"
}

source_ctl_functions() {
  local tmp="${TEST_TMPDIR}/ctl-functions.sh"
  # Replace placeholders, remove the case dispatch at the bottom so sourcing
  # only defines functions without executing a command.
  sed \
    -e 's/__HOSTNAME__/TESTHOST/g' \
    -e 's/__MONITORING_EMAIL__/test@example.com/g' \
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

@test "read_state: returns empty JSON when state file does not exist" {
  source_watchdog_functions
  rm -f "${STATE_FILE}"

  run read_state
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "read_state: returns file contents when state file exists" {
  source_watchdog_functions
  echo '{"consecutive_failures": 3}' >"${STATE_FILE}"

  run read_state
  [ "$status" -eq 0 ]
  [[ "$output" == *'"consecutive_failures": 3'* ]]
}

@test "write_state: creates state file atomically" {
  source_watchdog_functions
  local state='{"test": true}'

  write_state "${state}"

  [ -f "${STATE_FILE}" ]
  run cat "${STATE_FILE}"
  [[ "$output" == *'"test": true'* ]]

  # Verify no temp files left behind
  local tmp_count
  tmp_count=$(find "${CONFIG_DIR}" -name 'state.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$tmp_count" -eq 0 ]
}

@test "state_get: extracts value from state JSON" {
  source_watchdog_functions
  echo '{"consecutive_failures": 5, "response_hash": "abc123"}' >"${STATE_FILE}"

  run state_get "consecutive_failures" "0"
  [ "$output" = "5" ]

  run state_get "response_hash" ""
  [ "$output" = "abc123" ]
}

@test "state_get: returns default for missing keys" {
  source_watchdog_functions
  echo '{}' >"${STATE_FILE}"

  run state_get "consecutive_failures" "0"
  [ "$output" = "0" ]

  run state_get "missing_key" "default_val"
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
