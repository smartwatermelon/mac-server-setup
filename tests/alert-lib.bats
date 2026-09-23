#!/usr/bin/env bats
#
# Tests for alert-lib.sh — the shared alert email and state helpers sourced by
# plex-watchdog.sh and pia-port-watchdog.sh.
#
# The bug this library fixes: the watchdogs ran a bare `msmtp ... 2>/dev/null`.
# launchd's PATH (/usr/bin:/bin:/usr/sbin:/sbin) has no Homebrew in it, so
# every alert sent from a LaunchAgent failed, and 2>/dev/null threw away the
# only sign of it. So these tests pin three things: msmtp is found by absolute
# path, a failure is logged with msmtp's own stderr, and a failed send is not
# recorded as "alerted" (so it is retried instead of silently lost).
#
# Run with: bats tests/alert-lib.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
LIB="${REPO_DIR}/app-setup/templates/alert-lib.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR

  export HOME="${TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.config/msmtp"
  touch "${HOME}/.config/msmtp/config"

  # A fake Homebrew prefix. msmtp lives only here, never on PATH.
  export HOMEBREW_PREFIX="${TEST_TMPDIR}/brew"
  mkdir -p "${HOMEBREW_PREFIX}/bin"

  export MAIL_LOG="${TEST_TMPDIR}/mail.log"
  : >"${MAIL_LOG}"
  export MSMTP_ARGS_LOG="${TEST_TMPDIR}/msmtp-args.log"
  # A test creates this file to make the msmtp mock fail.
  export MSMTP_FAIL_FLAG="${TEST_TMPDIR}/msmtp-fail"
  write_msmtp_mock "${HOMEBREW_PREFIX}/bin/msmtp"

  export LOG_FILE="${TEST_TMPDIR}/caller.log"

  export STATE_FILE="${TEST_TMPDIR}/state.json"
  export MONITORING_EMAIL="ops@example.com"

  unset ALERT_MSMTP ALERT_MSMTP_CONFIG ALERT_REMINDER_SECONDS

  # shellcheck source=/dev/null
  source "${LIB}"

  # The caller's log function, in the watchdogs' format.
  log() {
    printf '[%s] [test-caller] %s\n' "now" "$1" >>"${LOG_FILE}"
  }
  log "test start"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# Mock msmtp: records the message and its arguments. If MSMTP_FAIL_FLAG
# exists, it fails the way real msmtp does on an auth error: stderr text and
# exit 77.
write_msmtp_mock() {
  cat >"$1" <<'MOCK'
#!/usr/bin/env bash
if [[ -f "${MSMTP_FAIL_FLAG}" ]]; then
  echo "msmtp: authentication failed (method PLAIN)" >&2
  echo "msmtp: server message: 535 5.7.8 Username and Password not accepted" >&2
  exit 77
fi
printf '%s\n' "$*" >>"${MSMTP_ARGS_LOG}"
{ echo "=== MAIL ==="; cat; } >>"${MAIL_LOG}"
MOCK
  chmod +x "$1"
}

mail_count() {
  grep -c '^=== MAIL ===' "${MAIL_LOG}" || true
}

state_field() {
  jq -r "$1" "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# alert_send: finding msmtp
# ---------------------------------------------------------------------------

@test "alert_send: finds msmtp under HOMEBREW_PREFIX with no msmtp on PATH" {
  PATH="/usr/bin:/bin:/usr/sbin:/sbin"

  run alert_send "subject" "body"
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
}

@test "alert_send: ALERT_MSMTP overrides the Homebrew path" {
  rm -f "${HOMEBREW_PREFIX}/bin/msmtp"
  mkdir -p "${TEST_TMPDIR}/elsewhere"
  write_msmtp_mock "${TEST_TMPDIR}/elsewhere/msmtp"
  export ALERT_MSMTP="${TEST_TMPDIR}/elsewhere/msmtp"

  run alert_send "subject" "body"
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
}

@test "alert_send: without HOMEBREW_PREFIX it derives the prefix from the CPU" {
  unset HOMEBREW_PREFIX
  local expected="/usr/local/bin/msmtp"
  if [[ "$(uname -m)" == "arm64" ]]; then
    expected="/opt/homebrew/bin/msmtp"
  fi

  run _alert_msmtp_path
  [ "$output" = "${expected}" ]
}

@test "alert_send: missing msmtp returns 1 and logs an ERROR naming the path" {
  rm -f "${HOMEBREW_PREFIX}/bin/msmtp"

  run alert_send "Lost port" "body"
  [ "$status" -eq 1 ]
  grep -q "ERROR: msmtp not found or not executable at ${HOMEBREW_PREFIX}/bin/msmtp" "${LOG_FILE}"
  grep -q "Lost port" "${LOG_FILE}"
}

@test "alert_send: missing msmtp config returns 1 and logs an ERROR" {
  rm -f "${HOME}/.config/msmtp/config"

  run alert_send "subject" "body"
  [ "$status" -eq 1 ]
  grep -q "ERROR: msmtp config not found at ${HOME}/.config/msmtp/config" "${LOG_FILE}"
  [ "$(mail_count)" -eq 0 ]
}

@test "alert_send: ALERT_MSMTP_CONFIG overrides the config path" {
  rm -f "${HOME}/.config/msmtp/config"
  touch "${TEST_TMPDIR}/other-config"
  export ALERT_MSMTP_CONFIG="${TEST_TMPDIR}/other-config"

  run alert_send "subject" "body"
  [ "$status" -eq 0 ]
  grep -q -- "-C ${TEST_TMPDIR}/other-config ops@example.com" "${MSMTP_ARGS_LOG}"
}

@test "alert_send: missing MONITORING_EMAIL returns 1 and logs an ERROR" {
  unset MONITORING_EMAIL

  run alert_send "subject" "body"
  [ "$status" -eq 1 ]
  grep -q "ERROR: MONITORING_EMAIL is not set" "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# alert_send: failures are logged, not discarded
# ---------------------------------------------------------------------------

@test "alert_send: an msmtp failure logs its exit code and stderr" {
  touch "${MSMTP_FAIL_FLAG}"

  run alert_send "Lost port" "body"
  [ "$status" -eq 1 ]
  grep -q "exited 77 sending 'Lost port'" "${LOG_FILE}"
  grep -q "authentication failed" "${LOG_FILE}"
  grep -q "535 5.7.8 Username and Password not accepted" "${LOG_FILE}"
  # Folded into one log line.
  [ "$(grep -c 'exited 77' "${LOG_FILE}")" -eq 1 ]
}

@test "alert_send: without a caller log function, errors go to stderr" {
  unset -f log
  rm -f "${HOMEBREW_PREFIX}/bin/msmtp"

  run alert_send "subject" "body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[alert-lib] ERROR: msmtp not found"* ]]
  ! grep -q "ERROR" "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# alert_send: message format (unchanged from the watchdogs' send_email)
# ---------------------------------------------------------------------------

@test "alert_send: sends Subject and To headers, a blank line, then the body" {
  alert_send "[HOST] Something broke" "line one
line two"

  local expected
  expected=$(printf '%s\n' "=== MAIL ===" "Subject: [HOST] Something broke" \
    "To: ops@example.com" "" "line one" "line two")
  [ "$(cat "${MAIL_LOG}")" = "${expected}" ]
  grep -q -- "-C ${HOME}/.config/msmtp/config ops@example.com" "${MSMTP_ARGS_LOG}"
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

@test "alert_state_read: {} when the state file does not exist" {
  run alert_state_read
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "alert_state_write: writes atomically and leaves no temp file" {
  alert_state_write '{"a": 1}'

  [ "$(state_field '.a')" = "1" ]
  [ "$(find "${TEST_TMPDIR}" -name 'state.json.tmp.*' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "alert_state_get: value, default for missing, default for false" {
  alert_state_write '{"n": 5, "s": "abc", "f": false}'

  [ "$(alert_state_get n 0)" = "5" ]
  [ "$(alert_state_get s)" = "abc" ]
  [ "$(alert_state_get missing dflt)" = "dflt" ]
  # jq's // treats false as absent; pia-port-watchdog relies on the default.
  [ "$(alert_state_get f "false")" = "false" ]
}

@test "state helpers fail loudly when STATE_FILE is unset" {
  unset STATE_FILE

  run alert_state_read
  [ "$status" -ne 0 ]
  [[ "$output" == *"STATE_FILE is not set"* ]]
}

# ---------------------------------------------------------------------------
# alert_transition
# ---------------------------------------------------------------------------

@test "alert_transition: entering the bad state sends one alert" {
  alert_transition tcc true "[HOST] TCC prompt pending" "click Allow"

  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[HOST\] TCC prompt pending" "${MAIL_LOG}"
  [ "$(state_field '.transitions.tcc.alerted')" = "true" ]
  [ "$(state_field '.transitions.tcc.since | type')" = "number" ]
  [ "$(state_field '.transitions.tcc.last_sent | type')" = "number" ]
  # The watchdog's own log must show the alert went out, not just msmtp.log.
  grep -q "ALERT sent: tcc: \[HOST\] TCC prompt pending" "${LOG_FILE}"
}

@test "alert_transition: a failed send logs no ALERT sent line" {
  touch "${MSMTP_FAIL_FLAG}"
  run alert_transition tcc true "subject" "body"
  [ "$(grep -c 'ALERT sent' "${LOG_FILE}")" -eq 0 ]
}

@test "alert_transition: staying bad sends nothing more" {
  alert_transition tcc true "subject" "body"
  alert_transition tcc true "subject" "body"
  alert_transition tcc true "subject" "body"

  [ "$(mail_count)" -eq 1 ]
}

@test "alert_transition: a failed send is not marked alerted and retries next call" {
  touch "${MSMTP_FAIL_FLAG}"
  run alert_transition tcc true "subject" "body"
  [ "$status" -eq 1 ]
  [ "$(mail_count)" -eq 0 ]
  [ "$(state_field '.transitions.tcc.alerted')" = "false" ]
  [ "$(state_field '.transitions.tcc.last_sent')" = "null" ]
  grep -q "exited 77" "${LOG_FILE}"
  local since
  since="$(state_field '.transitions.tcc.since')"

  rm -f "${MSMTP_FAIL_FLAG}"
  run alert_transition tcc true "subject" "body"
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
  [ "$(state_field '.transitions.tcc.alerted')" = "true" ]
  # "since" is when the condition started, not when the mail finally went out.
  [ "$(state_field '.transitions.tcc.since')" = "${since}" ]
}

@test "alert_transition: recovery sends one email, then resets" {
  alert_transition tcc true "[HOST] TCC prompt pending" "body"
  alert_transition tcc false "[HOST] TCC prompt pending" "body"

  [ "$(mail_count)" -eq 2 ]
  grep -q "Subject: RESOLVED: \[HOST\] TCC prompt pending" "${MAIL_LOG}"
  [ "$(state_field '.transitions.tcc')" = "null" ]

  alert_transition tcc false "[HOST] TCC prompt pending" "body"
  [ "$(mail_count)" -eq 2 ]

  # Re-armed: the next bad state alerts again.
  alert_transition tcc true "[HOST] TCC prompt pending" "body"
  [ "$(mail_count)" -eq 3 ]
}

@test "alert_transition: custom recovery subject and body are used" {
  alert_transition k true "down" "body"
  alert_transition k false "down" "body" "[HOST] back up" "all good now"

  grep -q "Subject: \[HOST\] back up" "${MAIL_LOG}"
  grep -q "all good now" "${MAIL_LOG}"
}

@test "alert_transition: good without a prior alert sends nothing" {
  alert_transition k false "down" "body"
  [ "$(mail_count)" -eq 0 ]
  [ ! -f "${STATE_FILE}" ]
}

@test "alert_transition: bad then good while the send kept failing sends no recovery" {
  touch "${MSMTP_FAIL_FLAG}"
  alert_transition k true "down" "body" || true
  rm -f "${MSMTP_FAIL_FLAG}"

  alert_transition k false "down" "body"
  [ "$(mail_count)" -eq 0 ]
  [ "$(state_field '.transitions.k')" = "null" ]
}

@test "alert_transition: two keys are independent" {
  alert_transition a true "A down" "body"
  alert_transition b false "B down" "body"
  [ "$(mail_count)" -eq 1 ]

  alert_transition a true "A down" "body"
  alert_transition b true "B down" "body"
  [ "$(mail_count)" -eq 2 ]

  alert_transition a false "A down" "body"
  [ "$(mail_count)" -eq 3 ]
  [ "$(state_field '.transitions.a')" = "null" ]
  [ "$(state_field '.transitions.b.alerted')" = "true" ]
}

@test "alert_transition: other top-level state keys are preserved" {
  alert_state_write '{"open_prompts": {"m1": {"service": "x"}}, "last_poll": "t"}'

  alert_transition k true "down" "body"
  alert_transition k false "down" "body"

  [ "$(state_field '.open_prompts.m1.service')" = "x" ]
  [ "$(state_field '.last_poll')" = "t" ]
}

@test "alert_transition: a corrupt state file is logged and replaced" {
  echo "not json" >"${STATE_FILE}"

  alert_transition k true "down" "body"
  [ "$(mail_count)" -eq 1 ]
  grep -q "is not a JSON object" "${LOG_FILE}"
  [ "$(state_field '.transitions.k.alerted')" = "true" ]
}

@test "alert_transition: a non-object .transitions is replaced, not written out as an empty file" {
  alert_state_write '{"transitions": "oops", "last_poll": "t"}'

  alert_transition k true "down" "body"
  [ "$(mail_count)" -eq 1 ]
  grep -q "\.transitions in .* is not a JSON object" "${LOG_FILE}"
  [ "$(state_field '.transitions.k.alerted')" = "true" ]
  [ "$(state_field '.last_poll')" = "t" ]

  # State survived, so the next run stays quiet instead of re-alerting.
  alert_transition k true "down" "body"
  [ "$(mail_count)" -eq 1 ]
}

@test "alert_transition: timestamps with a leading zero are read as decimal" {
  export ALERT_REMINDER_SECONDS=60
  alert_state_write '{"transitions": {"k": {"alerted": true, "since": "08", "last_sent": "09"}}}'

  run alert_transition k true "down" "body"
  [ "$status" -eq 0 ]
  # last_sent 9 is decades ago, so a reminder is due.
  [ "$(mail_count)" -eq 1 ]
  [ "$(state_field '.transitions.k.since')" = "8" ]
  jq -e . "${STATE_FILE}" >/dev/null
}

@test "alert_transition: no reminder unless ALERT_REMINDER_SECONDS is set" {
  alert_transition k true "down" "body"
  # Backdate the last send by a day.
  alert_state_write "$(jq '.transitions.k.last_sent -= 86400' "${STATE_FILE}")"

  alert_transition k true "down" "body"
  [ "$(mail_count)" -eq 1 ]
}

@test "alert_transition: reminder is sent after ALERT_REMINDER_SECONDS, not before" {
  export ALERT_REMINDER_SECONDS=3600
  alert_transition k true "down" "body"

  # Inside the interval: quiet.
  alert_transition k true "down" "body"
  [ "$(mail_count)" -eq 1 ]

  # Past the interval: one reminder, and last_sent moves forward.
  alert_state_write "$(jq '.transitions.k.last_sent -= 3601' "${STATE_FILE}")"
  local backdated
  backdated="$(state_field '.transitions.k.last_sent')"
  alert_transition k true "down" "body"
  [ "$(mail_count)" -eq 2 ]
  grep -q "Subject: \[reminder\] down" "${MAIL_LOG}"
  [ "$(state_field '.transitions.k.last_sent')" -gt "${backdated}" ]

  # And quiet again right after.
  alert_transition k true "down" "body"
  [ "$(mail_count)" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Runs under /bin/bash 3.2 (the LaunchAgents' interpreter)
# ---------------------------------------------------------------------------

@test "the library works under /bin/bash with launchd's PATH" {
  run env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="${HOME}" \
    HOMEBREW_PREFIX="${HOMEBREW_PREFIX}" MAIL_LOG="${MAIL_LOG}" \
    MSMTP_ARGS_LOG="${MSMTP_ARGS_LOG}" STATE_FILE="${STATE_FILE}" \
    MONITORING_EMAIL="ops@example.com" \
    /bin/bash -c '. "$1" && alert_transition k true "down" "body" \
      && alert_transition k true "down" "body" \
      && alert_transition k false "down" "body"' _ "${LIB}"
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 2 ]
}

@test "running the library directly refuses and exits 1" {
  run bash "${LIB}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"source it"* ]]
}
