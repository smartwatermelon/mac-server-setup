#!/usr/bin/env bats
#
# Tests for the podman-machine-start.sh supervisor loop (#123).
#
# podman-machine-start.sh is not a standalone file in the repo — it's a
# heredoc written out at deploy time by app-setup/podman-transmission-setup.sh
# (the `sudo tee "${MACHINE_START_DEST}" >/dev/null <<WRAPPER ... WRAPPER`
# block). This test extracts that heredoc body and re-expands it the same
# way the real deploy script does (unescaped ${VAR} tokens are deploy-time
# substitutions; \${VAR} tokens are escaped and become the deployed script's
# own runtime variables), using fixed test values in place of the real
# deploy-time variables (NFS_MOUNT_POINT, OPERATOR_HOME, HOST_PORT, etc.).
#
# A scripted `podman` mock is placed first in PATH and logs every invocation
# to $BATS_TMPDIR/podman.calls so tests can assert call order/counts without
# a real Podman machine or VM.
#
# Run with: bats tests/podman-machine-start.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/app-setup/podman-transmission-setup.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  MOCK_BIN_DIR="${TEST_TMPDIR}/bin"
  mkdir -p "${MOCK_BIN_DIR}"

  NFS_MOUNT_POINT="${TEST_TMPDIR}/nfs"
  OPERATOR_HOME="${TEST_TMPDIR}/home"
  mkdir -p "${NFS_MOUNT_POINT}" "${OPERATOR_HOME}/containers/transmission/scripts" \
    "${OPERATOR_HOME}/containers/transmission/config" "${OPERATOR_HOME}/containers/transmission/watch"
  touch "${OPERATOR_HOME}/containers/transmission/.env"

  CALLS_FILE="${TEST_TMPDIR}/podman.calls"
  : >"${CALLS_FILE}"
  export CALLS_FILE

  # State the podman mock reads/writes to decide how to respond. Backed by
  # files (not env vars) because each `podman` invocation is a fresh
  # process — mutations must persist across calls within a test.
  MACHINE_STATE_FILE="${TEST_TMPDIR}/machine.state"
  CONTAINER_EXISTS_FILE="${TEST_TMPDIR}/container.exists"
  CONTAINER_RUNNING_FILE="${TEST_TMPDIR}/container.running"
  export MACHINE_STATE_FILE CONTAINER_EXISTS_FILE CONTAINER_RUNNING_FILE

  set_mock_state "stopped" "false" "false"

  extract_and_render_wrapper
  write_podman_mock
  write_mount_mock
  link_timeout
}

# ---------------------------------------------------------------------------
# The wrapper resets PATH to "${HOMEBREW_PREFIX}/bin:...:/usr/bin:/bin", and
# the tests point HOMEBREW_PREFIX at the sandbox so the podman mock is found
# first. timeout(1) is coreutils, which lives in the real Homebrew prefix and
# is therefore off that PATH — so link it in. The wrapper now requires it and
# exits at startup without it (#168), which would fail every test here for a
# reason that has nothing to do with what is under test.
# ---------------------------------------------------------------------------
link_timeout() {
  local real_timeout
  real_timeout="$(command -v timeout || true)"
  if [[ -z "${real_timeout}" ]]; then
    echo "timeout(1) not found — install coreutils (brew install coreutils)" >&2
    return 1
  fi
  ln -sf "${real_timeout}" "${MOCK_BIN_DIR}/timeout"
}

# ---------------------------------------------------------------------------
# The wrapper's wait_for_nfs() checks `/sbin/mount | grep -q " on <mount> "`
# before entering the supervision loop. A plain mkdir'd tempdir is never a
# real mount, so shim `mount` to report NFS_MOUNT_POINT as mounted --
# exercising wait_for_nfs()'s real grep logic without requiring an actual
# filesystem mount in the test sandbox.
# ---------------------------------------------------------------------------
write_mount_mock() {
  cat >"${MOCK_BIN_DIR}/mount" <<MOCK_EOF
#!/usr/bin/env bash
echo "nfs-server:/export/path on ${NFS_MOUNT_POINT} (nfs)"
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/mount"
}

set_mock_state() {
  echo "$1" >"${MACHINE_STATE_FILE}"
  echo "$2" >"${CONTAINER_EXISTS_FILE}"
  echo "$3" >"${CONTAINER_RUNNING_FILE}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Extract the WRAPPER heredoc body from podman-transmission-setup.sh and
# re-expand its deploy-time ${VAR} tokens using test values, mirroring
# exactly what `sudo tee ... <<WRAPPER` does at real deploy time.
# ---------------------------------------------------------------------------
extract_and_render_wrapper() {
  local raw
  raw=$(awk '/^sudo tee "\$\{MACHINE_START_DEST\}" >\/dev\/null <<WRAPPER$/{flag=1; next} /^WRAPPER$/{flag=0} flag' "${SETUP_SCRIPT}")

  if [[ -z "${raw}" ]]; then
    echo "Failed to extract WRAPPER heredoc from ${SETUP_SCRIPT}" >&2
    return 1
  fi

  # These are consumed indirectly by the `eval "cat <<RENDER_EOF ..."` below
  # (shellcheck can't trace variable use through eval), so they're exported
  # rather than declared local/plain -- exported vars are assumed to have
  # external consumers and don't trip SC2034.
  # HOMEBREW_PREFIX's /bin subdirectory must resolve to MOCK_BIN_DIR so the
  # wrapper's own `export PATH="${HOMEBREW_PREFIX}/bin:..."` line picks up
  # the mocks first.
  export HOSTNAME_LOWER="testhost"
  export HOST_PORT="9091"
  export PIA_REGION="panama"
  export LAN="192.168.1.0/24"
  export PUID="501"
  export PGID="20"
  export TZ_VALUE="America/Los_Angeles"
  export HOMEBREW_PREFIX="${TEST_TMPDIR}"

  WRAPPER_SCRIPT="${TEST_TMPDIR}/podman-machine-start.sh"
  eval "cat <<RENDER_EOF
${raw}
RENDER_EOF" >"${WRAPPER_SCRIPT}"

  # wait_for_nfs() checks the real absolute path /sbin/mount, which can't be
  # PATH-shimmed. Rewrite to a bare `mount` invocation so the test's mock
  # (placed first in PATH) is used instead, without touching the real
  # /sbin/mount logic covered elsewhere. This is the only line altered from
  # what deploy actually writes.
  if ! grep -q '/sbin/mount' "${WRAPPER_SCRIPT}"; then
    echo "Expected /sbin/mount in rendered wrapper -- extraction may be stale" >&2
    return 1
  fi
  sed -i.bak 's#/sbin/mount#mount#' "${WRAPPER_SCRIPT}"
  rm -f "${WRAPPER_SCRIPT}.bak"

  chmod +x "${WRAPPER_SCRIPT}"
}

# ---------------------------------------------------------------------------
# Scripted podman mock: logs every invocation, responds based on state
# recorded in MACHINE_STATE_FILE / CONTAINER_EXISTS_FILE / CONTAINER_RUNNING_FILE
# (files, not env vars, so state persists across the mock's separate process
# invocations within a single test).
# ---------------------------------------------------------------------------
write_podman_mock() {
  cat >"${MOCK_BIN_DIR}/podman" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "$*" >>"${CALLS_FILE}"

# Dispatch on the full argument list (not just "$1 $2") so callers that pass
# extra flags -- e.g. `machine inspect transmission-vm --format '{{.State}}'`
# -- are matched by pattern rather than having those flags silently ignored.
case "$*" in
  "machine inspect"*)
    cat "${MACHINE_STATE_FILE}"
    exit 0
    ;;
  "machine start"*)
    echo "running" >"${MACHINE_STATE_FILE}"
    exit 0
    ;;
  "machine stop"*)
    echo "stopped" >"${MACHINE_STATE_FILE}"
    exit 0
    ;;
esac

case "$1" in
  info)
    exit 0
    ;;
  container)
    # podman container exists transmission-vpn
    [[ "$(cat "${CONTAINER_EXISTS_FILE}")" == "true" ]] && exit 0 || exit 1
    ;;
  inspect)
    if [[ "$(cat "${CONTAINER_RUNNING_FILE}")" == "true" ]]; then
      echo "true"
    else
      echo "false"
    fi
    exit 0
    ;;
  rm)
    exit 0
    ;;
  run)
    echo "true" >"${CONTAINER_EXISTS_FILE}"
    echo "true" >"${CONTAINER_RUNNING_FILE}"
    exit 0
    ;;
  exec)
    # check_data_access: podman exec transmission-vpn ls /data/
    exit 0
    ;;
  stop)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/podman"
}

call_count() {
  local pattern="$1"
  # grep -c prints "0" (correct) but exits 1 on zero matches. `|| true`
  # normalizes the exit status to 0 without affecting the printed count
  # (unlike `|| echo 0`, which would double-print on a real zero-match case).
  grep -Fc "${pattern}" "${CALLS_FILE}" 2>/dev/null || true
}

run_wrapper_briefly() {
  # Run under `timeout` with a short SUPERVISE_INTERVAL so the loop executes
  # a couple of iterations before being killed.
  SUPERVISE_INTERVAL=1 timeout 5 "${WRAPPER_SCRIPT}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "wrapper extraction: heredoc renders a syntactically valid script" {
  run bash -n "${WRAPPER_SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "wrapper extraction: deploy-time variables are substituted, not left literal" {
  run cat "${WRAPPER_SCRIPT}"
  [[ "${output}" == *"${NFS_MOUNT_POINT}"* ]]
  [[ "${output}" != *'${NFS_MOUNT_POINT}'* ]]
  [[ "${output}" == *"com.testhost.podman-transmission-vm"* ]]
}

@test "wrapper extraction: runtime variables remain escaped (not deploy-time substituted)" {
  run cat "${WRAPPER_SCRIPT}"
  [[ "${output}" == *'SUPERVISE_INTERVAL=${SUPERVISE_INTERVAL:-300}'* ]]
}

@test "supervisor: calls machine start exactly once when initial state is stopped" {
  set_mock_state "stopped" "true" "true"

  run run_wrapper_briefly

  local start_calls
  start_calls=$(call_count "machine start transmission-vm")
  [ "${start_calls}" -eq 1 ]
}

@test "supervisor: does not call machine start again once state is running" {
  set_mock_state "running" "true" "true"

  run run_wrapper_briefly

  local start_calls
  start_calls=$(call_count "machine start transmission-vm")
  [ "${start_calls}" -eq 0 ]
}

@test "supervisor: runs podman run for transmission-vpn exactly once when container is missing" {
  set_mock_state "running" "false" "false"

  run run_wrapper_briefly

  local run_calls
  run_calls=$(grep -c '^run -d' "${CALLS_FILE}" || true)
  [ "${run_calls}" -eq 1 ]
}

@test "supervisor: does not call podman run again once the container exists and is running" {
  set_mock_state "running" "true" "true"

  run run_wrapper_briefly

  local run_calls
  run_calls=$(grep -c '^run -d' "${CALLS_FILE}" || true)
  [ "${run_calls}" -eq 0 ]
}

@test "supervisor: does not exit on its own -- termination is caused by timeout, not the script" {
  set_mock_state "running" "true" "true"

  run run_wrapper_briefly

  # `timeout` returns 124 when it had to kill the command, confirming the
  # wrapper was still alive (in its `while true` supervision loop) and did
  # not exit voluntarily within the 5s budget.
  [ "${status}" -eq 124 ]
}

@test "supervisor: loop runs multiple health-check iterations before being killed" {
  set_mock_state "running" "true" "true"

  run run_wrapper_briefly

  # Each iteration calls `podman machine inspect` at minimum via
  # ensure_machine(). With SUPERVISE_INTERVAL=1 under a 5s timeout, expect
  # at least the initial pre-loop check plus 2+ loop iterations.
  local inspect_calls
  inspect_calls=$(call_count "machine inspect transmission-vm")
  [ "${inspect_calls}" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Timeout hardening (#168)
#
# On 2026-08-16 a `podman run -d` issued through a freshly upgraded 6.1.0 CLI,
# against a machine whose 6.0.2 gvproxy still held the socket paths, hung
# indefinitely. The supervision loop calls ensure_container synchronously, so
# the hang froze the entire loop for 27 hours: no log lines, no container,
# nothing listening on the web UI port, and none of the automatic recovery the
# loop exists to provide.
#
# The regression these tests protect is not "podman failed" — the loop already
# handled that — it is "podman never returned".
# ---------------------------------------------------------------------------

# Replace the podman mock with one that hangs on a chosen subcommand, so the
# no-longer-unbounded wait can actually be exercised.
write_hanging_podman_mock() {
  local hang_on="$1"
  cat >"${MOCK_BIN_DIR}/podman" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$*" >>"\${CALLS_FILE}"
if [[ "\$1" == "${hang_on}" ]]; then
  # Reproduce the 2026-08-16 hang: never return, never print.
  sleep 3600
fi
case "\$*" in
  "machine inspect"*) cat "\${MACHINE_STATE_FILE}"; exit 0 ;;
  "machine start"*)   echo running >"\${MACHINE_STATE_FILE}"; exit 0 ;;
  "machine stop"*)    echo stopped >"\${MACHINE_STATE_FILE}"; exit 0 ;;
esac
case "\$1" in
  info)      exit 0 ;;
  container) [[ "\$(cat "\${CONTAINER_EXISTS_FILE}")" == "true" ]] && exit 0 || exit 1 ;;
  inspect)   cat "\${CONTAINER_RUNNING_FILE}"; exit 0 ;;
  *)         exit 0 ;;
esac
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/podman"
}

@test "every podman call in the supervision loop is bounded by a timeout" {
  # The whole class of bug: any unbounded podman invocation can freeze the loop.
  # Assert none survive rather than enumerating the ones that were fixed, so a
  # newly added bare call fails this test instead of shipping.
  # Only command positions count. Comments legitimately name `podman machine
  # stop` in the header's maintenance notes, and log strings mention podman in
  # prose; neither is an invocation. A real call starts a line, follows `$(`,
  # or follows `!`/`&&`/`||`/`;`.
  run bash -c "grep -vE '^[[:space:]]*#' \"${WRAPPER_SCRIPT}\" | grep -nE '(^[[:space:]]*|\\\$\\(|[!;][[:space:]]*|&&[[:space:]]*|\\|\\|[[:space:]]*)podman[[:space:]]+[a-z]'"

  local line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    # podman_t's own body is the one place a bare `podman` is correct — it is
    # what _timeout wraps.
    [[ "${line}" == *'_timeout "${limit}" podman'* ]] && continue
    echo "unbounded podman call: ${line}" >&2
    return 1
  done <<<"${output}"
}

@test "a hung podman run is killed rather than freezing the loop forever" {
  set_mock_state "running" "false" "false"
  write_hanging_podman_mock "run"

  # 3s budget against a mock that sleeps for an hour. Before the fix this
  # blocked inside ensure_container and the loop never iterated again.
  PODMAN_MACHINE_TIMEOUT=2 PODMAN_CMD_TIMEOUT=2 SUPERVISE_INTERVAL=1 \
    run timeout 12 "${WRAPPER_SCRIPT}"

  # Killed by the outer timeout means the wrapper was still looping, not stuck.
  [ "${status}" -eq 124 ]

  # The decisive evidence: the loop kept going past the hung call.
  local run_calls
  run_calls=$(grep -c '^run -d' "${CALLS_FILE}" || true)
  [ "${run_calls}" -ge 2 ]
}

@test "a timed-out podman call is logged distinctly from an ordinary failure" {
  set_mock_state "running" "false" "false"
  write_hanging_podman_mock "run"

  PODMAN_MACHINE_TIMEOUT=2 PODMAN_CMD_TIMEOUT=2 SUPERVISE_INTERVAL=1 \
    run timeout 8 "${WRAPPER_SCRIPT}"

  # An operator reading the log has to be able to tell a hang from a failure —
  # that distinction is what took 27 hours to spot the first time.
  [[ "${output}" == *"TIMEOUT:"* ]]
  [[ "${output}" == *"exceeded"* ]]
  # Name the subcommand, not the forty-flag argv that buries it.
  [[ "${output}" == *"TIMEOUT: 'podman run -d' exceeded"* ]]
}

@test "a hung machine inspect does not prevent later loop iterations" {
  set_mock_state "running" "true" "true"
  write_hanging_podman_mock "machine"

  # Every `machine` subcommand hangs here, so each iteration burns the full
  # timeout on inspect and again on start. Budget accordingly: 1s timeouts and
  # a 15s run leave room for several iterations. Before the fix the first
  # inspect never returned and there was no second iteration at all.
  PODMAN_MACHINE_TIMEOUT=1 PODMAN_CMD_TIMEOUT=1 SUPERVISE_INTERVAL=1 \
    run timeout 15 "${WRAPPER_SCRIPT}"

  [ "${status}" -eq 124 ]
  local inspect_calls
  inspect_calls=$(call_count "machine inspect transmission-vm")
  [ "${inspect_calls}" -ge 2 ]
}

# ---------------------------------------------------------------------------
# Stale helper reaping (#168)
# ---------------------------------------------------------------------------

@test "the machine stop path verifies helper processes exited, not just the exit code" {
  # `podman machine stop` returned 0 in the August incident while a 6.0.2
  # gvproxy kept running for seven more days, still holding the socket paths
  # the upgraded CLI then tried to reuse.
  run grep -c 'reap_machine_helpers' "${WRAPPER_SCRIPT}"
  # Defined once, called from the recovery path and before a machine start.
  [ "${output}" -ge 3 ]
}

@test "reap_machine_helpers escalates to SIGKILL for a helper that ignores SIGTERM" {
  run grep -A 30 '^reap_machine_helpers()' "${WRAPPER_SCRIPT}"
  [[ "${output}" == *"kill -0"* ]]
  [[ "${output}" == *"kill -9"* ]]
}

@test "reap_machine_helpers only targets this machine's helpers" {
  # An unqualified `pkill gvproxy` would take down every other podman machine
  # on the host. The match has to be scoped to transmission-vm.
  run grep -A 12 '^reap_machine_helpers()' "${WRAPPER_SCRIPT}"
  [[ "${output}" == *"transmission-vm"* ]]
}

# ---------------------------------------------------------------------------
# Startup sequence
# ---------------------------------------------------------------------------

@test "a failed initial machine start does not silently fall through to container create" {
  # Contributing factor in #168: ensure_machine's return value was ignored at
  # the top-level call sites, so a machine failure surfaced later as a
  # confusing container error.
  run grep -A 6 '^wait_for_nfs || exit 1' "${WRAPPER_SCRIPT}"
  [[ "${output}" == *"if ensure_machine; then"* ]]
}

@test "the loop refuses to start without timeout(1) rather than running unbounded" {
  # A supervision loop that cannot bound its subprocesses cannot recover from a
  # hang, which is the whole failure mode of #168. Exiting loudly beats running
  # in a state that only looks supervised.
  rm -f "${MOCK_BIN_DIR}/timeout"

  run timeout 10 "${WRAPPER_SCRIPT}"

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FATAL: timeout(1) not found"* ]]
  [[ "${output}" == *"brew install coreutils"* ]]

  # And it must bail before touching podman at all.
  [ ! -s "${CALLS_FILE}" ]
}
