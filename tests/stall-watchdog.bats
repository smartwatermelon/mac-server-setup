#!/usr/bin/env bats
#
# Tests for app-setup/templates/stall-watchdog.sh (#199).
#
# The template is rendered the way podman-transmission-setup.sh renders it,
# with HOMEBREW_PREFIX pointed at a fake prefix whose bin holds the msmtp and
# ps mocks (the watchdog sets its own PATH, prefix first). The unified-log CLI
# is reached through TCC_LOG_BIN, because a bare `log` would be the script's
# own log() function; its mock serves ndjson from fixture files.
#
# The tccd message text in the fixtures is copied from the real prompt of
# 2026-09-23 09:22 on TILSIT (msgID 17928.48, user tccd pid 446). Timestamps
# are generated relative to now, in log show's own format.
#
# Run with: bats tests/stall-watchdog.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE="${REPO_DIR}/app-setup/templates/stall-watchdog.sh"

PROMPT_MSG='AUTHREQ_PROMPTING: msgID=17928.48, service=kTCCServiceSystemPolicyNetworkVolumes, subject=Sub:{/usr/local/stable/bash/bin/bash}Resp:{TCCDProcess: identifier=local.tilsit.stable.bash, pid=36425, auid=502, euid=502, responsible_path=/usr/local/stable/bash/bin/bash, binary_path=/usr/local/stable/bash/bin/bash},'
RESULT_MSG='AUTHREQ_RESULT: msgID=17928.48, authValue=2, authReason=2, authVersion=1, desired_auth=0, error=(null),'
USER_TCCD=446
SYSTEM_TCCD=174

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

  export MAIL_LOG="${TEST_TMPDIR}/mail.log"
  : >"${MAIL_LOG}"

  export PROMPT_FILE="${TEST_TMPDIR}/prompts.ndjson"
  export RESULT_FILE="${TEST_TMPDIR}/results.ndjson"
  export LOG_FAIL_FILE="${TEST_TMPDIR}/log.fail"
  export LOG_STDERR_FILE="${TEST_TMPDIR}/log.stderr"
  export LOG_CALLS="${TEST_TMPDIR}/log.calls"
  : >"${PROMPT_FILE}"
  : >"${RESULT_FILE}"
  : >"${LOG_CALLS}"

  export PS_FILE="${TEST_TMPDIR}/ps.out"
  export ALIVE_FILE="${TEST_TMPDIR}/alive.pids"
  printf '  101    03:17:33 /bin/bash /Users/operator/.local/bin/transmission-trigger-watcher.sh\n' >"${PS_FILE}"
  printf '%s\n%s\n' "${USER_TCCD}" "${SYSTEM_TCCD}" >"${ALIVE_FILE}"

  export TCC_LOG_BIN="${TEST_TMPDIR}/log-mock"
  write_log_mock
  write_ps_mock
  write_msmtp_mock
  render_template
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

render_template() {
  WATCHDOG="${TEST_TMPDIR}/stall-watchdog.sh"
  sed \
    -e "s|__SERVER_NAME__|TESTHOST|g" \
    -e "s|__MONITORING_EMAIL__|ops@example.com|g" \
    -e "s|HOMEBREW_PREFIX=\"[^\"]*\"|HOMEBREW_PREFIX=\"${FAKE_BREW}\"|" \
    "${TEMPLATE}" >"${WATCHDOG}"
  chmod +x "${WATCHDOG}"
  export WATCHDOG
}

# `log show --start S --style ndjson --predicate P`: records S, then serves the
# prompt or result fixture by what P asks for, then log show's trailer record.
write_log_mock() {
  cat >"${TCC_LOG_BIN}" <<'MOCK'
#!/usr/bin/env bash
start=""
predicate=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) start="$2"; shift 2 ;;
    --predicate) predicate="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "${start}|${predicate}" >>"${LOG_CALLS}"
if [[ -f "${LOG_FAIL_FILE}" ]]; then
  echo "log: Could not open log archive" >&2
  exit 64
fi
[[ -f "${LOG_STDERR_FILE}" ]] && echo "log: warning: some noise on stderr" >&2
case "${predicate}" in
  *AUTHREQ_PROMPTING*) cat "${PROMPT_FILE}" ;;
  *AUTHREQ_RESULT*) cat "${RESULT_FILE}" ;;
esac
echo '{"count":0,"finished":1}'
MOCK
  chmod +x "${TCC_LOG_BIN}"
}

# `ps -axo pid=,etime=,command=` serves PS_FILE; `ps -p PID -o comm=` answers
# "tccd" for pids listed in ALIVE_FILE and fails for the rest.
write_ps_mock() {
  cat >"${MOCK_BIN_DIR}/ps" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-p" ]]; then
  if grep -qx "$2" "${ALIVE_FILE}"; then
    echo "/usr/libexec/tccd"
    exit 0
  fi
  exit 1
fi
cat "${PS_FILE}"
MOCK
  chmod +x "${MOCK_BIN_DIR}/ps"
}

write_msmtp_mock() {
  cat >"${MOCK_BIN_DIR}/msmtp" <<'MOCK'
#!/usr/bin/env bash
{ echo "=== MAIL ==="; cat; } >>"${MAIL_LOG}"
MOCK
  chmod +x "${MOCK_BIN_DIR}/msmtp"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# log show's timestamp format for an epoch, e.g. 2026-09-23 09:22:13.080738-0700
log_ts() {
  date -r "$1" '+%Y-%m-%d %H:%M:%S.080738%z'
}

# tcc_line FILE SECONDS_AGO TCCD_PID MESSAGE
tcc_line() {
  local ts
  ts="$(log_ts $(($(date +%s) - $2)))"
  jq -nc --arg ts "${ts}" --argjson pid "$3" --arg m "$4" \
    '{timestamp: $ts, processID: $pid, userID: 502, subsystem: "com.apple.TCC", category: "access", eventMessage: $m}' >>"$1"
}

run_cycle() {
  bash "${WATCHDOG}"
}

mail_count() {
  grep -c '^=== MAIL ===' "${MAIL_LOG}" || true
}

state() {
  jq -r "$1" "${HOME}/.config/stall-watchdog/state.json"
}

watchdog_log() {
  cat "${HOME}/.local/state/testhost-stall-watchdog.log" 2>/dev/null || true
}

write_state() {
  mkdir -p "${HOME}/.config/stall-watchdog"
  printf '%s\n' "$1" >"${HOME}/.config/stall-watchdog/state.json"
}

# ===========================================================================
# Check 1: TCC prompts
# ===========================================================================

@test "tcc: no prompts in the log sends nothing and records the scan" {
  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 0 ]
  [ "$(state '.tcc_prompts // {} | length')" -eq 0 ]
  [ "$(state '.tcc_last_scan')" != "null" ]
}

@test "tcc: a prompt open for 2 minutes is recorded but not alerted" {
  tcc_line "${PROMPT_FILE}" 120 "${USER_TCCD}" "${PROMPT_MSG}"

  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 0 ]
  [ "$(state '.tcc_prompts["446/17928.48"].service')" = "kTCCServiceSystemPolicyNetworkVolumes" ]
  [ "$(state '.tcc_prompts["446/17928.48"].subject')" = "/usr/local/stable/bash/bin/bash" ]
}

@test "tcc: since comes from the log timestamp, not from when the scan ran" {
  tcc_line "${PROMPT_FILE}" 120 "${USER_TCCD}" "${PROMPT_MSG}"
  local expected
  expected=$(($(date +%s) - 120))

  run run_cycle
  local since
  since="$(state '.tcc_prompts["446/17928.48"].since')"
  [ $((since - expected)) -le 1 ]
  [ $((expected - since)) -le 1 ]
}

@test "tcc: a prompt open for 6 minutes sends one alert naming the binary" {
  tcc_line "${PROMPT_FILE}" 360 "${USER_TCCD}" "${PROMPT_MSG}"

  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] macOS privacy prompt is blocking the server" "${MAIL_LOG}"
  grep -q "for /usr/local/stable/bash/bin/bash" "${MAIL_LOG}"
  grep -q "click Allow" "${MAIL_LOG}"

  # The next cycle stays quiet: one alert per incident.
  run run_cycle
  [ "$(mail_count)" -eq 1 ]
}

@test "tcc: the answer closes the prompt and sends one recovery email" {
  tcc_line "${PROMPT_FILE}" 360 "${USER_TCCD}" "${PROMPT_MSG}"
  run_cycle
  [ "$(mail_count)" -eq 1 ]

  tcc_line "${RESULT_FILE}" 10 "${USER_TCCD}" "${RESULT_MSG}"
  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 2 ]
  grep -q "Subject: RESOLVED: \[TESTHOST\] macOS privacy prompt answered" "${MAIL_LOG}"
  # 350 s: measured to the answer's own timestamp, not to when the scan ran.
  grep -q "closed after 5m: answered" "${MAIL_LOG}"
  [ "$(state '.tcc_prompts | length')" -eq 0 ]
}

@test "tcc: a prompt answered inside 5 minutes never alerts" {
  tcc_line "${PROMPT_FILE}" 20 "${USER_TCCD}" "${PROMPT_MSG}"
  tcc_line "${RESULT_FILE}" 10 "${USER_TCCD}" "${RESULT_MSG}"

  run run_cycle
  [ "$(mail_count)" -eq 0 ]
  [ "$(state '.tcc_prompts | length')" -eq 0 ]
}

@test "tcc: a RESULT with the same msgID from the system tccd does not close it" {
  tcc_line "${PROMPT_FILE}" 360 "${USER_TCCD}" "${PROMPT_MSG}"
  run_cycle
  [ "$(mail_count)" -eq 1 ]

  tcc_line "${RESULT_FILE}" 10 "${SYSTEM_TCCD}" "${RESULT_MSG}"
  run run_cycle
  [ "$(mail_count)" -eq 1 ]
  [ "$(state '.tcc_prompts["446/17928.48"].service')" = "kTCCServiceSystemPolicyNetworkVolumes" ]
}

@test "tcc: an unanswered prompt is never dropped and reminds every 12 hours" {
  local now
  now=$(date +%s)
  # Open for a day, alerted 13 hours ago, and its lines long gone from the log.
  write_state "{
    \"tcc_last_scan\": $((now - 120)),
    \"tcc_prompts\": {\"446/17928.48\": {\"since\": $((now - 86400)),
      \"service\": \"kTCCServiceSystemPolicyNetworkVolumes\",
      \"subject\": \"/usr/local/stable/bash/bin/bash\", \"tccd_pid\": 446}},
    \"transitions\": {\"tcc_prompt\": {\"alerted\": true, \"since\": $((now - 86100)),
      \"last_sent\": $((now - 46800))}}
  }"

  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[reminder\] \[TESTHOST\] macOS privacy prompt is blocking the server" "${MAIL_LOG}"
  [ "$(grep -c "RESOLVED" "${MAIL_LOG}")" -eq 0 ]
  [ "$(state '.tcc_prompts["446/17928.48"].since')" -eq $((now - 86400)) ]
}

@test "tcc: a prompt whose tccd has exited is closed, and the email says why" {
  tcc_line "${PROMPT_FILE}" 360 "${USER_TCCD}" "${PROMPT_MSG}"
  run_cycle
  [ "$(mail_count)" -eq 1 ]

  : >"${PROMPT_FILE}"
  echo "${SYSTEM_TCCD}" >"${ALIVE_FILE}"
  run run_cycle
  [ "$(mail_count)" -eq 2 ]
  grep -q "its tccd process exited" "${MAIL_LOG}"
  [ "$(state '.tcc_prompts | length')" -eq 0 ]
}

@test "tcc: log show failing keeps open prompts and alerts on the third failure" {
  tcc_line "${PROMPT_FILE}" 120 "${USER_TCCD}" "${PROMPT_MSG}"
  run_cycle
  [ "$(state '.tcc_prompts | length')" -eq 1 ]

  touch "${LOG_FAIL_FILE}"
  run_cycle
  run_cycle
  [ "$(mail_count)" -eq 0 ]
  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] stall-watchdog cannot read the system log" "${MAIL_LOG}"
  [[ "$(watchdog_log)" == *"exited 64: log: Could not open log archive"* ]]
  [ "$(state '.tcc_prompts | length')" -eq 1 ]
}

@test "tcc: stderr noise from log show does not break parsing" {
  touch "${LOG_STDERR_FILE}"
  tcc_line "${PROMPT_FILE}" 360 "${USER_TCCD}" "${PROMPT_MSG}"

  run run_cycle
  [ "$(mail_count)" -eq 1 ]
}

@test "tcc: the scan starts a minute before the last one" {
  local now
  now=$(date +%s)
  write_state "{\"tcc_last_scan\": $((now - 600))}"

  run_cycle
  local start expected
  start="$(head -1 "${LOG_CALLS}" | cut -d'|' -f1)"
  expected="$(date -r $((now - 660)) '+%Y-%m-%d %H:%M')"
  [[ "${start}" == "${expected}"* ]]
}

@test "tcc: after a long gap the scan looks back at most an hour" {
  local now
  now=$(date +%s)
  write_state "{\"tcc_last_scan\": $((now - 86400))}"

  run_cycle
  local start expected
  start="$(head -1 "${LOG_CALLS}" | cut -d'|' -f1)"
  expected="$(date -r $((now - 3600)) '+%Y-%m-%d %H:%M')"
  [[ "${start}" == "${expected}"* ]]
}

@test "tcc: log timestamps parse to the same epoch in any TZ" {
  local la utc
  la="$(TZ=America/Los_Angeles TEST_RUNNER=true bash -c \
    'source "$1" >/dev/null 2>&1; log_ts_epoch "2026-09-23 09:22:13.080738-0700"' _ "${WATCHDOG}")"
  utc="$(TZ=UTC TEST_RUNNER=true bash -c \
    'source "$1" >/dev/null 2>&1; log_ts_epoch "2026-09-23 09:22:13.080738-0700"' _ "${WATCHDOG}")"
  [ "${la}" = "1790180533" ]
  [ "${utc}" = "1790180533" ]
}

# ===========================================================================
# Check 2: transmission-done running long
# ===========================================================================

@test "done: etime parses mm:ss, hh:mm:ss and dd-hh:mm:ss" {
  run env TEST_RUNNER=true bash -c \
    'source "$1" >/dev/null 2>&1; etime_seconds 05:10; echo; etime_seconds 01:02:03; echo; etime_seconds 1-00:00:08' \
    _ "${WATCHDOG}"
  [ "${lines[0]}" = "310" ]
  [ "${lines[1]}" = "3723" ]
  [ "${lines[2]}" = "86408" ]
}

@test "done: a run of a few minutes is quiet" {
  printf '  202       05:10 /usr/local/stable/bash/bin/bash /Users/operator/.local/bin/transmission-done\n' >>"${PS_FILE}"

  run run_cycle
  [ "$(mail_count)" -eq 0 ]
}

@test "done: a run over 45 minutes sends one alert, and recovery when it ends" {
  printf '  202    01:02:03 /usr/local/stable/bash/bin/bash /Users/operator/.local/bin/transmission-done\n' >>"${PS_FILE}"

  run run_cycle
  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] transmission-done has been running for over 45 minutes" "${MAIL_LOG}"
  grep -q "pid 202, running 1h 2m" "${MAIL_LOG}"

  run run_cycle
  [ "$(mail_count)" -eq 1 ]

  printf '  101    03:17:33 /bin/bash /Users/operator/.local/bin/transmission-trigger-watcher.sh\n' >"${PS_FILE}"
  run run_cycle
  [ "$(mail_count)" -eq 2 ]
  grep -q "Subject: RESOLVED: \[TESTHOST\] transmission-done" "${MAIL_LOG}"
}

@test "done: the trigger watcher itself is not mistaken for transmission-done" {
  # Its command line has no "transmission-done" in it, but it runs for days.
  printf '  101  3-03:17:33 /bin/bash /Users/operator/.local/bin/transmission-trigger-watcher.sh\n' >"${PS_FILE}"

  run run_cycle
  [ "$(mail_count)" -eq 0 ]
}

# ===========================================================================
# Check 3: supervisor status
# ===========================================================================

supervisor_status() {
  printf '%s\n' "$1" >"${HOME}/.local/state/testhost-supervisor-status.json"
}

@test "supervisor: a missing status file is unknown and alerts nothing" {
  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 0 ]
}

@test "supervisor: two consecutive failures are quiet" {
  supervisor_status "{\"consecutive_failures\": 2, \"last_error\": \"ensure_container failed\", \"updated_at\": $(date +%s)}"

  run run_cycle
  [ "$(mail_count)" -eq 0 ]
}

@test "supervisor: three consecutive failures alert with the last error" {
  supervisor_status "{\"consecutive_failures\": 3, \"last_error\": \"ensure_machine failed\", \"updated_at\": $(date +%s)}"

  run run_cycle
  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] podman supervisor has failed 3 cycles in a row" "${MAIL_LOG}"
  grep -q "Last error: ensure_machine failed" "${MAIL_LOG}"
}

@test "supervisor: a status file not updated for over an hour alerts" {
  supervisor_status "{\"consecutive_failures\": 0, \"last_error\": \"\", \"updated_at\": $(($(date +%s) - 4000))}"

  run run_cycle
  [ "$(mail_count)" -eq 1 ]
  grep -q "Subject: \[TESTHOST\] podman supervisor has stopped reporting" "${MAIL_LOG}"
}

@test "supervisor: a healthy, fresh status is quiet" {
  supervisor_status "{\"consecutive_failures\": 0, \"last_error\": \"\", \"updated_at\": $(date +%s)}"

  run run_cycle
  [ "$(mail_count)" -eq 0 ]
}

@test "supervisor: a corrupt status file is logged and skipped" {
  supervisor_status "not json"

  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 0 ]
  [[ "$(watchdog_log)" == *"is not a JSON object"* ]]
}

# ===========================================================================
# launchd environment
# ===========================================================================

@test "launchd PATH: the prompt alert is sent under /bin/bash with launchd's PATH" {
  tcc_line "${PROMPT_FILE}" 360 "${USER_TCCD}" "${PROMPT_MSG}"

  run env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="${HOME}" \
    TCC_LOG_BIN="${TCC_LOG_BIN}" PROMPT_FILE="${PROMPT_FILE}" RESULT_FILE="${RESULT_FILE}" \
    LOG_FAIL_FILE="${LOG_FAIL_FILE}" LOG_STDERR_FILE="${LOG_STDERR_FILE}" LOG_CALLS="${LOG_CALLS}" \
    PS_FILE="${PS_FILE}" ALIVE_FILE="${ALIVE_FILE}" MAIL_LOG="${MAIL_LOG}" \
    /bin/bash "${WATCHDOG}"
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 1 ]
}

@test "a missing alert library stops the watchdog with an ERROR in its log" {
  rm "${HOME}/.local/lib/alert-lib.sh"

  run run_cycle
  [ "$status" -eq 1 ]
  [[ "$(watchdog_log)" == *"ERROR: alert library not found"* ]]
}

# ===========================================================================
# Deploy wiring in podman-transmission-setup.sh
# ===========================================================================

SETUP_SCRIPT="${REPO_DIR}/app-setup/podman-transmission-setup.sh"

@test "deploy: every placeholder is substituted in the rendered watchdog" {
  run grep -c '__[A-Z_]*__' "${WATCHDOG}"
  [ "$output" -eq 0 ]
}

@test "deploy: the setup script substitutes every placeholder the template declares" {
  local placeholder block
  block="$(grep -A 30 'Deploying stall-watchdog.sh' "${SETUP_SCRIPT}")"
  [ -n "${block}" ]
  while IFS= read -r placeholder; do
    grep -q "s|${placeholder}|" <<<"${block}" || {
      echo "stall-watchdog deploy never substitutes ${placeholder}" >&2
      return 1
    }
  done < <(grep -oE '__[A-Z_]+__' "${TEMPLATE}" | sort -u)
}

@test "deploy: only when it can send mail, and with the alert library" {
  run grep -A 16 'STALL_WATCHDOG_DEPLOY=true' "${SETUP_SCRIPT}"
  [[ "$output" == *"MONITORING_EMAIL"* ]]
  [[ "$output" == *"msmtp"* ]]
  run grep -A 12 'if \[\[ "${STALL_WATCHDOG_DEPLOY}" == "true" \]\]; then' "${SETUP_SCRIPT}"
  [[ "$output" == *'sudo cp "${ALERT_LIB_TEMPLATE}" "${ALERT_LIB_DEST}"'* ]]
}

@test "deploy: the LaunchAgent runs /bin/bash every 2 minutes, starting at load" {
  run grep -A 26 'stall-watchdog.plist"' "${SETUP_SCRIPT}"
  [[ "$output" == *"<string>/bin/bash</string>"* ]]
  [[ "$output" == *'<string>${OPERATOR_HOME}/.local/bin/stall-watchdog.sh</string>'* ]]
  [[ "$output" == *"<integer>120</integer>"* ]]
  [[ "$output" == *"<key>RunAtLoad</key>"*"<true/>"* ]]
}
