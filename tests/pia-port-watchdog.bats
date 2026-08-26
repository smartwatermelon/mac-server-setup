#!/usr/bin/env bats
#
# Tests for pia-port-watchdog.sh — the alert for lost PIA port forwarding.
#
# The behaviour under test is what made the August outage invisible (issue
# #181): downloads keep working without a forwarded port, so nothing that
# watches download activity notices. Only newly added torrents break. Port
# forwarding was dead for about 47 hours and nothing alerted.
#
# Two mistakes would make this watchdog worse than useless:
#
#   1. Alerting on the transient zero the peer port legitimately shows for a
#      few seconds during a container restart. A watchdog that cries wolf gets
#      filtered, and then the real outage is invisible again.
#
#   2. Alerting every cycle. At a 15-minute cadence a 47-hour outage is ~190
#      identical emails, which has the same end result.
#
# The script uses the same TEST_RUNNER hook as cloudflare-ddns.sh and
# pia-pf-probe.sh: TEST_RUNNER=true before sourcing skips `main "$@"`.
#
# Run with: bats tests/pia-port-watchdog.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE="${REPO_DIR}/app-setup/templates/pia-port-watchdog.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  MOCK_BIN_DIR="${TEST_TMPDIR}/bin"
  mkdir -p "${MOCK_BIN_DIR}"

  # HOME drives every path the script writes to, so pointing it at the sandbox
  # keeps state, logs and the msmtp config out of the real home directory.
  export HOME="${TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.config/msmtp" "${HOME}/.local/state"
  touch "${HOME}/.config/msmtp/config"

  export MAIL_LOG="${TEST_TMPDIR}/mail.log"
  : >"${MAIL_LOG}"

  # RPC responses are read from files so a test can change what Transmission
  # reports between invocations.
  export RPC_PEER_PORT_FILE="${TEST_TMPDIR}/peer_port"
  export RPC_PORT_OPEN_FILE="${TEST_TMPDIR}/port_open"
  export RPC_REACHABLE_FILE="${TEST_TMPDIR}/reachable"
  echo "51413" >"${RPC_PEER_PORT_FILE}"
  echo "true" >"${RPC_PORT_OPEN_FILE}"
  echo "true" >"${RPC_REACHABLE_FILE}"

  write_curl_mock
  write_msmtp_mock
  render_template
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Render the template the way podman-transmission-setup.sh does, so the tests
# exercise what actually gets deployed rather than the placeholder version.
# ---------------------------------------------------------------------------
render_template() {
  WATCHDOG="${TEST_TMPDIR}/pia-port-watchdog.sh"
  sed \
    -e "s|__SERVER_NAME__|TESTHOST|g" \
    -e "s|__MONITORING_EMAIL__|ops@example.com|g" \
    -e "s|__TRANSMISSION_HOST_PORT__|9091|g" \
    "${TEMPLATE}" >"${WATCHDOG}"
  chmod +x "${WATCHDOG}"
  export WATCHDOG
}

# ---------------------------------------------------------------------------
# curl mock. Serves the CSRF handshake, then session-get / port-test from the
# state files. `-D -` (header dump) marks the session-id request.
# ---------------------------------------------------------------------------
write_curl_mock() {
  cat >"${MOCK_BIN_DIR}/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$(cat "${RPC_REACHABLE_FILE}")" != "true" ]]; then
  exit 7
fi

for arg in "$@"; do
  if [[ "${arg}" == "-D" ]]; then
    printf 'HTTP/1.1 409 Conflict\r\nX-Transmission-Session-Id: testtoken\r\n\r\n'
    exit 0
  fi
done

body=""
for arg in "$@"; do
  case "${arg}" in
    *'"method":"session-get"'*)
      body="{\"arguments\":{\"peer-port\":$(cat "${RPC_PEER_PORT_FILE}")},\"result\":\"success\"}"
      ;;
    *'"method":"port-test"'*)
      body="{\"arguments\":{\"port-is-open\":$(cat "${RPC_PORT_OPEN_FILE}")},\"result\":\"success\"}"
      ;;
  esac
done

printf '%s' "${body}"
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

set_rpc() {
  echo "$1" >"${RPC_PEER_PORT_FILE}"
  echo "$2" >"${RPC_PORT_OPEN_FILE}"
}

run_cycle() {
  bash "${WATCHDOG}"
}

mail_count() {
  grep -c '^=== MAIL ===' "${MAIL_LOG}" || true
}

state_field() {
  jq -r "$1" "${HOME}/.config/pia-port-watchdog/state.json"
}

watchdog_log() {
  cat "${HOME}/.local/state/testhost-pia-port-watchdog.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Healthy state
# ---------------------------------------------------------------------------

@test "a forwarded, reachable port produces no alert" {
  set_rpc "51413" "true"

  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 0 ]
  [ "$(state_field '.consecutive_failures')" -eq 0 ]
  [ "$(state_field '.alerted')" = "false" ]
}

# ---------------------------------------------------------------------------
# Transient badness must not alert (#181: "don't alert on transient state")
# ---------------------------------------------------------------------------

@test "a single bad poll does not alert" {
  # The peer port reads 0 for a few seconds during a container restart. Paging
  # on that trains everyone to ignore the alert.
  set_rpc "0" "false"

  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 0 ]
  [ "$(state_field '.consecutive_failures')" -eq 1 ]
}

@test "two bad polls still do not alert" {
  set_rpc "0" "false"

  run_cycle
  run_cycle

  [ "$(mail_count)" -eq 0 ]
  [ "$(state_field '.consecutive_failures')" -eq 2 ]
}

@test "a bad poll followed by a good one resets the streak" {
  set_rpc "0" "false"
  run_cycle
  run_cycle
  [ "$(state_field '.consecutive_failures')" -eq 2 ]

  set_rpc "51413" "true"
  run_cycle

  [ "$(state_field '.consecutive_failures')" -eq 0 ]
  [ "$(mail_count)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Sustained loss must alert, exactly once
# ---------------------------------------------------------------------------

@test "three consecutive bad polls alert" {
  set_rpc "0" "false"

  run_cycle
  run_cycle
  run_cycle

  [ "$(mail_count)" -eq 1 ]
  [ "$(state_field '.alerted')" = "true" ]
  grep -q "Transmission port forwarding lost" "${MAIL_LOG}"
}

@test "a continuing outage does not send a second alert" {
  # 47 hours at a 15-minute cadence is ~190 emails if this is wrong, which is
  # just a different way of not being noticed.
  set_rpc "0" "false"

  # Eight cycles of a continuing outage; only the first crossing of the
  # threshold may send mail.
  local remaining=8
  while [[ ${remaining} -gt 0 ]]; do
    run_cycle
    remaining=$((remaining - 1))
  done

  [ "$(mail_count)" -eq 1 ]
}

@test "recovery sends exactly one all-clear and re-arms" {
  set_rpc "0" "false"
  run_cycle
  run_cycle
  run_cycle
  [ "$(mail_count)" -eq 1 ]

  set_rpc "51413" "true"
  run_cycle
  [ "$(mail_count)" -eq 2 ]
  grep -q "port forwarding restored" "${MAIL_LOG}"
  [ "$(state_field '.alerted')" = "false" ]

  # Another cycle while healthy must stay quiet.
  run_cycle
  [ "$(mail_count)" -eq 2 ]

  # A second loss has to alert again — the state was re-armed, not latched.
  set_rpc "0" "false"
  run_cycle
  run_cycle
  run_cycle
  [ "$(mail_count)" -eq 3 ]
}

# ---------------------------------------------------------------------------
# The subtler failure: a real port that nobody outside can reach
# ---------------------------------------------------------------------------

@test "a non-zero but unreachable port is treated as lost forwarding" {
  # This is the state the port guard (#180) deliberately leaves behind on a PF
  # failure: the existing port is kept rather than zeroed, so port != 0 while
  # forwarding is gone. Checking only for zero would miss it entirely.
  set_rpc "51413" "false"

  run_cycle
  run_cycle
  run_cycle

  [ "$(mail_count)" -eq 1 ]
  grep -q "not reachable from outside" "${MAIL_LOG}"
}

@test "an unknown reachability result is not treated as a failure" {
  # port-test can fail to answer for reasons unrelated to forwarding. Guessing
  # "no" would alert on a tracker hiccup.
  set_rpc "51413" "null"

  run_cycle
  run_cycle
  run_cycle

  [ "$(mail_count)" -eq 0 ]
  [ "$(state_field '.consecutive_failures')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Transmission being down is a different problem
# ---------------------------------------------------------------------------

@test "an unreachable Transmission is skipped, not reported as lost forwarding" {
  echo "false" >"${RPC_REACHABLE_FILE}"

  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(mail_count)" -eq 0 ]
  [[ "$(watchdog_log)" == *"RPC unreachable"* ]]
}

@test "an unreachable Transmission does not advance the failure streak" {
  # Otherwise a container that is down for an hour eventually alerts about port
  # forwarding, which is the wrong diagnosis and sends the reader somewhere
  # unhelpful. The container health check already covers this case.
  set_rpc "0" "false"
  run_cycle
  run_cycle
  [ "$(state_field '.consecutive_failures')" -eq 2 ]

  echo "false" >"${RPC_REACHABLE_FILE}"
  run_cycle
  run_cycle
  run_cycle

  [ "$(mail_count)" -eq 0 ]
  [ "$(state_field '.consecutive_failures')" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Alert content
# ---------------------------------------------------------------------------

@test "the alert explains why the failure is invisible and where to look" {
  set_rpc "0" "false"
  run_cycle
  run_cycle
  run_cycle

  # Without this context the reader sees "port forwarding lost" and reasonably
  # concludes downloads have stopped, which is not what happens.
  grep -q "Newly added" "${MAIL_LOG}"
  grep -q "podman logs" "${MAIL_LOG}"
  grep -q "pia-pf-probe.sh" "${MAIL_LOG}"
}

# ---------------------------------------------------------------------------
# Deployment wiring
# ---------------------------------------------------------------------------

@test "every placeholder is substituted at deploy time" {
  run grep -c '__[A-Z_]*__' "${WATCHDOG}"
  [ "$output" -eq 0 ]
}

@test "the setup script substitutes exactly the placeholders the template declares" {
  local placeholder
  while IFS= read -r placeholder; do
    grep -q "s|${placeholder}|" "${REPO_DIR}/app-setup/podman-transmission-setup.sh" \
      || {
        echo "setup script never substitutes ${placeholder}" >&2
        return 1
      }
  done < <(grep -oE '__[A-Z_]+__' "${TEMPLATE}" | sort -u)
}

@test "the watchdog is only deployed when it can actually send mail" {
  # An agent that runs every 15 minutes and can only log "cannot send email" is
  # worse than no agent: it looks like monitoring without being any.
  run grep -A 12 'PORT_WATCHDOG_DEPLOY=true' "${REPO_DIR}/app-setup/podman-transmission-setup.sh"
  [[ "$output" == *"MONITORING_EMAIL"* ]]
  [[ "$output" == *"msmtp"* ]]
}

@test "the LaunchAgent polls often enough to catch a loss within the hour" {
  run grep -A 20 'pia-port-watchdog.plist' "${REPO_DIR}/app-setup/podman-transmission-setup.sh"
  [[ "$output" == *"<integer>900</integer>"* ]]
}

@test "the remediation path in the alert is a path that actually gets deployed" {
  # The alert tells an operator to run pia-pf-probe.sh at a specific path. If
  # nothing deploys it there the advice is worse than none: it sends someone
  # mid-incident to a file that does not exist. The repo checkout is not an
  # answer — the operator account does not have one.
  # Build the tilde from its character code rather than writing one: a literal
  # ~ inside quotes trips SC2088, which is a false positive here (this is a
  # grep pattern, not a path being expanded).
  local tilde
  tilde="$(printf '\176')"

  local referenced
  referenced="$(grep -oE "${tilde}/[a-zA-Z0-9_./-]*pia-pf-probe\.sh" "${TEMPLATE}" | head -1)"
  [ -n "${referenced}" ]

  # Reduce the referenced path to the part below the container directory, which
  # is what the setup script's destination is expressed relative to.
  local suffix="${referenced#"${tilde}"/containers/transmission/}"
  [ "${suffix}" = "scripts/pia-pf-probe.sh" ]

  run grep -q 'PF_PROBE_DEST="\${CONTAINER_DIR}/scripts/pia-pf-probe.sh"' \
    "${REPO_DIR}/app-setup/podman-transmission-setup.sh"
  [ "$status" -eq 0 ]

  # And it must actually be copied, not just have a variable defined for it.
  run grep -q 'sudo cp "\${PF_PROBE_TEMPLATE}" "\${PF_PROBE_DEST}"' \
    "${REPO_DIR}/app-setup/podman-transmission-setup.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Heartbeat state writes (#184)
#
# The healthy path used to write the state file twice per cycle: once inside
# maybe_heartbeat with a fresh last_heartbeat but every other field still
# holding the previous cycle's values, then again in main with the real ones.
# Individually each write is atomic, so the file was never torn — but a kill
# landing between them persisted a current heartbeat next to a stale port and
# failure count. maybe_heartbeat now returns the timestamp instead of storing
# it, so a cycle's state advances in one write or not at all.
# ---------------------------------------------------------------------------

@test "maybe_heartbeat does not write state itself" {
  # Structural: the whole point of the change is that this function has no
  # write_state call left in it. Behavioural tests below cannot distinguish
  # one write from two, so assert on the function body directly.
  #
  # Ask bash for the body via declare -f rather than slicing the file with
  # awk. A text extractor has to guess where the function ends, and every
  # cheap guess ("the next } at column 0") breaks the day someone adds a case
  # statement or a nested block closed in column 0: the extract silently comes
  # back truncated, write_state is missing from the part that was read, and
  # this test goes green for the wrong reason. bash has already parsed the
  # function, so it knows the real boundaries.
  local body
  body="$(TEST_RUNNER=true bash -c \
    'source "$1" >/dev/null 2>&1; declare -f maybe_heartbeat' _ "${WATCHDOG}")"

  # Guard the guard: an empty body would make the assertion below vacuous.
  [ -n "${body}" ]
  grep -q 'maybe_heartbeat' <<<"${body}"
  ! grep -q 'write_state' <<<"${body}"
}

@test "a healthy cycle records a heartbeat and the current port together" {
  set_rpc "51413" "true"

  run run_cycle
  [ "$status" -eq 0 ]

  # One consistent snapshot: the heartbeat is real, and it sits next to this
  # cycle's port rather than a previous cycle's.
  [ "$(state_field '.last_heartbeat')" != "null" ]
  [ "$(state_field '.last_heartbeat')" != "1970-01-01T00:00:00Z" ]
  [ "$(state_field '.peer_port')" = "51413" ]
  [ "$(state_field '.port_is_open')" = "yes" ]
}

@test "a heartbeat inside the interval is not rewritten" {
  set_rpc "51413" "true"
  run_cycle
  local first
  first="$(state_field '.last_heartbeat')"

  # HEARTBEAT_INTERVAL_SECONDS is an hour, so an immediate second cycle is
  # well inside it: the timestamp must survive unchanged rather than being
  # refreshed or dropped.
  set_rpc "51414" "true"
  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(state_field '.last_heartbeat')" = "${first}" ]

  # ...while the rest of the cycle's data still advances.
  [ "$(state_field '.peer_port')" = "51414" ]
}

@test "a bad cycle does not invent a heartbeat it never logged" {
  # The old code defaulted the carried-forward value to now, so a first cycle
  # that found the port broken wrote a heartbeat that never happened — which
  # then suppressed the first real one for a full interval.
  set_rpc "0" "false"

  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(state_field '.last_heartbeat')" = "1970-01-01T00:00:00Z" ]
  ! grep -q 'OK: peer port' <<<"$(watchdog_log)"
}

@test "the first healthy cycle after a bad one logs its heartbeat immediately" {
  set_rpc "0" "false"
  run_cycle

  set_rpc "51413" "true"
  run run_cycle
  [ "$status" -eq 0 ]
  [ "$(state_field '.last_heartbeat')" != "1970-01-01T00:00:00Z" ]
  grep -q 'OK: peer port 51413' <<<"$(watchdog_log)"
}
